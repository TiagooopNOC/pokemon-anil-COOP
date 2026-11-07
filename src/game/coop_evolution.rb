# Selected-owner post-battle evolution. Never invoke the global after_battle hooks.
class AnilCoopEvolutionScene < PokemonEvolutionScene
  def pbUpdate(animating = false)
    super(animating)
    AnilCoop.battle_tick
  end
end

class AnilCoopQAEvolutionScene < AnilCoopEvolutionScene
  # Programmed confirmation uses the game's own autoresume control, not OS input.
  def pbMessageDisplay(window, message, letterbyletter = true, command_proc = nil, &block)
    raise "QA evolution requires a menu selection" if command_proc
    super(window, message.delete("\x01") + "\\^", letterbyletter, nil) do
      window.resume if window.respond_to?(:pausing?) && window.pausing?
      block.call if block
      AnilCoop.battle_tick
    end
  end

  def pbConfirmMessage(message, &block)
    # Full move slots: keep the existing moves in unattended QA. Empty-slot
    # learning still runs through the original pbLearnMove implementation.
    AnilCoop.log("QA evolution declined optional prompt: #{message}")
    false
  end
end

module AnilCoop
  def self.evolve_selected(plan)
    receipt = $PokemonGlobal.anil_coop_receipts&.dig(plan[:battle])
    raise "Evolución sin resultado aplicado" unless receipt && receipt[:player_id] == $player.id &&
      $player.equal?(plan[:player]) && $PokemonGlobal.equal?(plan[:global])
    return [] if [2, 5].include?(receipt[:decision]) && !Settings::CHECK_EVOLUTION_AFTER_ALL_BATTLES
    @evolution_processed ||= {}
    evolved = []
    qa = !!ENV["ANIL_COOP_QA_BOT"]
    plan[:selected].each do |selection|
      slot = selection[:slot]
      pokemon = $player.party[slot]
      raise "Equipo cambiado antes de evolucionar" unless pokemon.equal?(selection[:pokemon]) &&
        pokemon_key(pokemon) == selection[:key]
      key = [plan[:player_id], plan[:battle], slot]
      next if @evolution_processed[key]
      # These bytes were captured from the owner's own trusted Pokemon in RAM.
      before = Marshal.load(plan[:party_bytes].fetch(slot))
      next unless pokemon.species == before.species && pokemon.level > before.level
      next if pokemon.egg? || (pokemon.fainted? && !Settings::CHECK_EVOLUTION_FOR_FAINTED_POKEMON)
      if pokemon.species == :NINCADA
        log("evolution pending slot=#{slot}: Nincada/Shedinja needs a party-capacity adapter")
        pbMessage("La evolución cooperativa de Nincada está pendiente de adaptación.") { battle_tick } unless qa
        @evolution_processed[key] = true
        next
      end
      new_species = pokemon.check_evolution_on_level_up
      next unless new_species
      scene = qa ? AnilCoopQAEvolutionScene.new : AnilCoopEvolutionScene.new
      started = false
      begin
        scene.pbStartScreen(pokemon, new_species)
        started = true
        scene.pbEvolution(!qa)
      ensure
        scene.pbEndScreen if started
      end
      @evolution_processed[key] = true
      next if pokemon.species == before.species # The human may cancel normally.
      evolved << { slot: slot, from: before.species, to: pokemon.species }
      log("personal evolution slot=#{slot} #{before.species}->#{pokemon.species}")
    end
    evolved
  end
end
