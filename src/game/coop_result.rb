# Local result transaction. All Marshal operations below use trusted local objects.
# Receipts are saved alongside the party by the game's ordinary SaveData path.
class PokemonGlobalMetadata
  attr_accessor :anil_coop_receipts
end

module AnilCoop
  RESULT_FIELDS = [:@exp, :@level, :@ev, :@moves, :@hp, :@status, :@statusCount,
                   :@happiness, :@item, :@pokerus, :@totalhp, :@attack, :@defense,
                   :@spatk, :@spdef, :@speed, :@perma_faint, :@hyper_mode,
                   :@ready_to_evolve].freeze

  def self.capture_result_plan(state, original_player, original_global)
    raise "Resultado sin equipo personal" unless state["prototype"] == "personal2v2-v1"
    battle_id = state["battle"]
    raise "Identificador de combate inválido" unless battle_id.is_a?(String) && battle_id.match?(/\A[0-9a-f]{32}\z/)
    index = state.fetch("participants").index { |p| p["id"] == @id }
    sizes = state.fetch("team_sizes")
    teams = state.fetch("selected_teams")
    raise "Propietario del resultado inválido" unless index && [0, 1].include?(index) &&
      sizes.length == 2 && sizes.all? { |size| size.is_a?(Integer) && size.between?(1, 3) } &&
      teams.length == 2 && teams.each_with_index.all? { |team, i| team.length == sizes[i] }
    party = original_player.party.dup
    raise "Equipo personal inválido" unless party.length.between?(1, 6) && party.uniq.length == party.length
    selected = teams[index].map do |snapshot|
      slot = snapshot["slot"]
      raise "Posición personal inválida" unless slot.is_a?(Integer) && slot.between?(0, party.length - 1)
      pokemon = party[slot]
      raise "El Pokémon cambió después de seleccionarlo" unless
        pokemon_key(pokemon) == snapshot["key"] && team_snapshot(pokemon, slot) == snapshot
      { slot: slot, key: snapshot["key"], pokemon: pokemon }
    end
    raise "Selección personal repetida" unless selected.map { |s| s[:slot] }.uniq.length == selected.length &&
      selected.map { |s| s[:key] }.uniq.length == selected.length
    receipts = original_global.anil_coop_receipts
    raise "Registro de resultados inválido" unless receipts.nil? || receipts.is_a?(Hash)
    { battle: battle_id, player: original_player, global: original_global,
      player_id: original_player.id, party: party, party_bytes: party.map { |p| Marshal.dump(p) },
      selected: selected, offset: sizes.take(index).sum, team_sizes: sizes.dup,
      money: original_player.money, receipt_bytes: Marshal.dump(receipts) }
  end

  # Prepare on a clone of the ORIGINAL Pokemon, preserving all personal extension
  # fields. Copy only battle outcomes from the native engine's temporary Pokemon.
  def self.prepare_personal_result(original_bytes, source, expected_key)
    pokemon = Marshal.load(original_bytes)
    raise "Identidad de Pokémon alterada" unless pokemon_key(source) == expected_key &&
      source.species == pokemon.species && source.form_simple == pokemon.form_simple
    raise "Estado final no compatible" if source.egg? || source.shadowPokemon? || source.fused
    pokemon.exp = source.exp
    pokemon.ev = Marshal.load(Marshal.dump(source.ev))
    pokemon.moves = Marshal.load(Marshal.dump(source.moves))
    pokemon.happiness = source.happiness
    pokemon.item = source.item_id
    pokemon.pokerus = source.pokerus
    pokemon.calc_stats
    raise "Estadísticas finales incompatibles" unless
      [pokemon.totalhp, pokemon.attack, pokemon.defense, pokemon.spatk, pokemon.spdef, pokemon.speed] ==
      [source.totalhp, source.attack, source.defense, source.spatk, source.spdef, source.speed]
    # Run the original setter under the restored owner's challenge rules. It marks
    # perma-faint on zero HP and clears status/evolution readiness as the game does.
    pokemon.hp = source.hp
    if pokemon.hp > 0
      pokemon.status = source.status
      pokemon.statusCount = source.statusCount
      pokemon.ready_to_evolve = true if source.ready_to_evolve
    end
    pokemon
  end

  def self.apply_personal_result(plan, battle_party, decision, money: 0)
    raise "Resultado no aplicable" unless [1, 2, 5].include?(decision) && decision.is_a?(Integer)
    raise "Recompensa inválida" unless money.is_a?(Integer) && money.between?(0, Settings::MAX_MONEY) &&
      (money == 0 || decision == 1)
    raise "Perfil diferente" unless $player.id == plan[:player_id]
    receipts = $PokemonGlobal.anil_coop_receipts
    raise "Registro de resultados inválido" unless receipts.nil? || receipts.is_a?(Hash)
    expected_receipt = { player_id: plan[:player_id], decision: decision,
                         keys: plan[:selected].map { |s| s[:key] }, money: money }
    if receipts && receipts.key?(plan[:battle])
      raise "Resultado repetido contradictorio" unless receipts[plan[:battle]] == expected_receipt
      return false
    end
    raise "Resultado sin acuerdo de ambos jugadores" unless @battle_completed && @active_battle == plan[:battle]
    raise "Perfil cambiado durante el combate" unless $player.equal?(plan[:player]) && $PokemonGlobal.equal?(plan[:global])
    raise "Equipo cambiado durante el combate" unless $player.party.length == plan[:party].length &&
      $player.party.each_with_index.all? { |p, i| p.equal?(plan[:party][i]) && Marshal.dump(p) == plan[:party_bytes][i] }
    raise "Perfil modificado durante el combate" unless $player.money == plan[:money] &&
      Marshal.dump(receipts) == plan[:receipt_bytes]
    raise "Equipo final incompleto" unless battle_party.is_a?(Array) && battle_party.length == plan[:team_sizes].sum
    prepared = plan[:selected].each_with_index.map do |selection, i|
      prepare_personal_result(plan[:party_bytes][selection[:slot]],
                              battle_party.fetch(plan[:offset] + i), selection[:key])
    end
    # A synchronous commit: no graphics, network, prompts or saves may yield here.
    backups = plan[:selected].map do |selection|
      p = selection[:pokemon]
      p.instance_variables.to_h { |name| [name, p.instance_variable_get(name)] }
    end
    receipt_defined = $PokemonGlobal.instance_variable_defined?(:@anil_coop_receipts)
    old_money = $player.money
    begin
      plan[:selected].each_with_index do |selection, i|
        target = selection[:pokemon]
        source = prepared[i]
        RESULT_FIELDS.each do |field|
          if source.instance_variable_defined?(field)
            target.instance_variable_set(field, source.instance_variable_get(field))
          elsif target.instance_variable_defined?(field)
            target.remove_instance_variable(field)
          end
        end
      end
      selected_slots = plan[:selected].map { |s| s[:slot] }
      untouched = plan[:party].each_with_index.all? { |p, i|
        selected_slots.include?(i) || Marshal.dump(p) == plan[:party_bytes][i] }
      raise "Se alteró un Pokémon no seleccionado" unless untouched
      $player.money = old_money + money if money > 0
      $PokemonGlobal.anil_coop_receipts = (receipts || {}).merge(plan[:battle] => expected_receipt)
    rescue Exception
      # Restore the same Pokemon objects, including their original nested references.
      plan[:selected].each_with_index do |selection, i|
        target = selection[:pokemon]
        (target.instance_variables - backups[i].keys).each { |field| target.remove_instance_variable(field) }
        backups[i].each { |field, value| target.instance_variable_set(field, value) }
      end
      $player.instance_variable_set(:@money, old_money)
      if receipt_defined
        $PokemonGlobal.anil_coop_receipts = receipts
      elsif $PokemonGlobal.instance_variable_defined?(:@anil_coop_receipts)
        $PokemonGlobal.remove_instance_variable(:@anil_coop_receipts)
      end
      raise
    end
    { applied: true, selected_count: plan[:selected].length, unselected_unchanged: true }
  end
end
