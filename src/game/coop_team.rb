# Explicit JSON battle snapshots. Never deserialize Ruby objects from the network.
class AnilCoopPokemon < Pokemon
  attr_accessor :coop_types, :coop_base_stats
  def types; @coop_types || super; end
  def baseStats; @coop_base_stats || super; end
end

module AnilCoop
  TEAM_STATS = [:HP, :ATTACK, :DEFENSE, :SPECIAL_ATTACK, :SPECIAL_DEFENSE, :SPEED]

  def self.personal_team?; ENV["ANIL_COOP_PERSONAL_TEAM"] == "1"; end
  def self.battle_prototype; personal_team? ? "personal2v2-v1" : "qa2v2-v1"; end
  def self.pokemon_key(p); "#{p.owner.id}:#{p.personalID}"; end

  def self.team_eligible?(p)
    p && p.able? && !p.egg? && !p.shadowPokemon? && !p.fused
  end

  def self.team_snapshot(p, slot)
    raise "Pokémon no utilizable" unless team_eligible?(p)
    {
      "key" => pokemon_key(p), "slot" => slot, "species" => p.species.to_s,
      "name" => p.name, "level" => p.level, "exp" => p.exp, "form" => p.form,
      "pid" => p.personalID, "owner" => { "id" => p.owner.id, "name" => p.owner.name,
        "gender" => p.owner.gender, "language" => p.owner.language },
      "gender" => p.gender, "shiny" => p.shiny?, "super_shiny" => p.super_shiny?,
      "ability" => p.ability_id.to_s, "nature" => p.nature.id.to_s,
      "nature_stats" => p.nature_for_stats.id.to_s, "item" => p.item_id&.to_s,
      "moves" => p.moves.map { |m| [m.id.to_s, m.pp, m.ppup] },
      "iv" => TEAM_STATS.map { |s| p.iv[s] }, "ev" => TEAM_STATS.map { |s| p.ev[s] },
      "maxed" => TEAM_STATS.map { |s| !!p.ivMaxed[s] },
      "stats" => [p.totalhp, p.attack, p.defense, p.spatk, p.spdef, p.speed],
      "base_stats" => TEAM_STATS.map { |s| p.baseStats[s] }, "types" => p.types.map(&:to_s),
      "hp" => p.hp, "status" => p.status.to_s, "status_count" => p.statusCount,
      "happiness" => p.happiness, "pokerus" => p.pokerus, "ball" => p.poke_ball.to_s
    }
  end

  def self.trainer_snapshot
    { "id" => $player.id, "name" => $player.name, "gender" => $player.gender,
      "language" => $player.language, "trainer_type" => $player.trainer_type.to_s }
  end

  def self.team_pokemon(data)
    # Server validates shape/ranges; the game additionally validates every database ID.
    registries = { "species" => GameData::Species, "ability" => GameData::Ability,
      "nature" => GameData::Nature, "nature_stats" => GameData::Nature,
      "status" => GameData::Status, "ball" => GameData::Item }
    registries.each { |k, registry| raise "ID incompatible: #{k}" unless registry.exists?(data[k]) }
    raise "Objeto incompatible" if data["item"] && !GameData::Item.exists?(data["item"])
    data["moves"].each { |m| raise "Movimiento incompatible" unless GameData::Move.exists?(m[0]) }
    data["types"].each { |t| raise "Tipo incompatible" unless GameData::Type.exists?(t) }
    owner = data.fetch("owner")
    p = AnilCoopPokemon.new(data["species"].to_sym, data["level"],
      Pokemon::Owner.new(owner["id"], owner["name"], owner["gender"], owner["language"]), false, false, false)
    p.personalID = data["pid"]
    p.form_simple = data["form"]
    p.name = data["name"]
    p.gender = data["gender"]
    p.shiny = data["shiny"]
    p.super_shiny = data["super_shiny"]
    p.ability = p.forced_ability = data["ability"].to_sym
    p.nature = data["nature"].to_sym
    p.nature_for_stats = data["nature_stats"].to_sym
    p.item = data["item"]&.to_sym
    p.coop_types = data["types"].map(&:to_sym)
    p.coop_base_stats = TEAM_STATS.zip(data["base_stats"]).to_h
    TEAM_STATS.each_with_index do |stat, i|
      p.iv[stat], p.ev[stat], p.ivMaxed[stat] = data["iv"][i], data["ev"][i], data["maxed"][i]
    end
    p.exp = data["exp"]
    p.calc_stats
    raise "Estadísticas incompatibles" unless p.level == data["level"] &&
      [p.totalhp, p.attack, p.defense, p.spatk, p.spdef, p.speed] == data["stats"]
    p.moves = data["moves"].map do |id, pp, ppup|
      m = Pokemon::Move.new(id.to_sym)
      m.ppup = ppup
      raise "PP incompatibles" if pp > m.total_pp
      m.pp = pp
      m
    end
    p.hp = data["hp"]
    p.status = data["status"].to_sym
    p.statusCount = data["status_count"]
    p.happiness = data["happiness"]
    p.pokerus = data["pokerus"]
    p.poke_ball = data["ball"].to_sym
    p
  end

  def self.select_team(indices)
    raise "Elegí entre uno y tres Pokémon" unless indices.length.between?(1, 3) && indices.uniq == indices
    team = indices.map { |i| team_snapshot($player.party.fetch(i), i) }
    raise "Identificadores repetidos" unless team.map { |p| p["key"] }.uniq.length == team.length
    @selected_team = team
    team
  end

  def self.choose_team(event)
    AnilCoopTeamSelection.new(event).run
  end
end

# Añil's real party scene draws the icons, names, levels, HP and status. The
# numbered badges sit over its panels, so annotations never hide HP or status.
class AnilCoopTeamScene < PokemonParty_Scene
  def pbStartScene(*args)
    super
    max_party_size.times do |i|
      panel = @sprites["pokemon#{i}"]
      badge = BitmapSprite.new(22, 20, @viewport)
      badge.x = panel.x + 48
      badge.y = panel.y + 2
      badge.z = panel.z + 6
      badge.visible = false
      @sprites["coop_order#{i}"] = badge
    end
  end

  def coop_show_order(chosen)
    max_party_size.times do |i|
      badge = @sprites["coop_order#{i}"]
      order = chosen.index(i)
      badge.visible = !order.nil?
      next unless order
      bitmap = badge.bitmap
      bitmap.clear
      bitmap.fill_rect(0, 0, 22, 20, Color.new(40, 40, 40))
      bitmap.fill_rect(2, 2, 18, 16, Color.new(240, 200, 72))
      pbSetSmallFont(bitmap)
      pbDrawTextPositions(bitmap, [[(order + 1).to_s, 11, -2, :center,
                                    Color.new(24, 24, 24), Color.new(248, 248, 248)]])
    end
  end

end

class AnilCoopTeamSelection
  def initialize(event)
    @event = event
  end

  def run
    chosen = previous_selection
    scene = AnilCoopTeamScene.new
    AnilCoop.instance_variable_set(:@team_menu_active, true)
    scene.pbStartScene($player.party, "Elegí de 1 a 3 Pokémon en orden.", nil, true)
    scene.coop_show_order(chosen)
    loop do
      scene.pbSetHelpText("Equipo #{chosen.length}/3. Elegí o confirmá.")
      slot = scene.pbChoosePokemon
      return false if slot < 0
      if slot == max_party_size
        if chosen.empty?
          scene.pbDisplay("Elegí al menos un Pokémon.")
          next
        end
        begin
          team = AnilCoop.select_team(chosen)
          AnilCoop.trainer_send("trainer_team", @event, team: team, trainer: AnilCoop.trainer_snapshot)
          return true
        rescue StandardError => e
          scene.pbDisplay(e.message)
          next
        end
      end
      next if slot >= $player.party.length
      pokemon = $player.party[slot]
      order = chosen.index(slot)
      commands = []
      commands << "Agregar al equipo cooperativo" if !order && AnilCoop.team_eligible?(pokemon)
      commands << "Quitar del equipo cooperativo" if order
      commands << "Subir en el orden" if order && order > 0
      commands << "Bajar en el orden" if order && order < chosen.length - 1
      commands << "Datos"
      commands << "Cancelar"
      choice = scene.pbShowCommands("¿Qué hacer con #{pokemon.name}?", commands)
      next if choice < 0
      case commands[choice]
      when "Agregar al equipo cooperativo"
        if chosen.length >= 3
          scene.pbDisplay("El equipo cooperativo admite hasta tres Pokémon.")
        else
          chosen << slot
        end
      when "Quitar del equipo cooperativo"
        chosen.delete(slot)
      when "Subir en el orden"
        chosen[order - 1], chosen[order] = chosen[order], chosen[order - 1]
      when "Bajar en el orden"
        chosen[order + 1], chosen[order] = chosen[order], chosen[order + 1]
      when "Datos"
        scene.pbSummary(slot)
      end
      scene.coop_show_order(chosen)
    end
  ensure
    AnilCoop.instance_variable_set(:@team_menu_active, false)
    scene&.pbEndScene if scene&.instance_variable_get(:@sprites)
  end

  private

  def previous_selection
    Array(AnilCoop.instance_variable_get(:@selected_team)).filter_map do |snapshot|
      slot = snapshot["slot"]
      pokemon = $player.party[slot] if slot.is_a?(Integer)
      slot if AnilCoop.team_eligible?(pokemon) && AnilCoop.pokemon_key(pokemon) == snapshot["key"]
    end.uniq.first(3)
  end
end
