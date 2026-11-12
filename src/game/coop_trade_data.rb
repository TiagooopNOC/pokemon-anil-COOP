# Lossless, versioned Pokémon representation. This is data only: it neither
# changes a party nor participates in the preview or save protocol.
# No network value is ever passed to Marshal.load or to a class constructor.
module AnilCoopTradeData
  VERSION = 1
  MAX_BYTES = 65_536
  MAX_DEPTH = 12
  MAX_ELEMENTS = 4_096
  # Essentials 21.1, Añil's local edits, and the installed Randomizer,
  # Nuzlocke, Legacy Data, animated DBK, Spinda and trading charm plugins.
  # An unknown instance variable makes the Pokémon ineligible for transfer.
  FIELDS = %w[
    species form forced_form time_form_set exp level steps_to_hatch hp status
    statusCount gender shiny super_shiny ability_index ability nature
    nature_for_stats item mail moves first_moves ribbons cool beauty cute smart
    tough sheen pokerus name happiness poke_ball markings iv ivMaxed ev
    evo_move_count evo_crest_count evo_recoil_count evo_step_count owner
    obtain_method obtain_map obtain_text obtain_level hatched_map timeReceived
    timeEggHatched fused personalID totalhp attack defense spatk spdef speed
    previous_form shadow saved_exp saved_ev shadow_moves heart_gauge
    heart_gauge_step_counter hyper_mode mirrorherb_steps ready_to_evolve
    cannot_store cannot_release cannot_trade cached_super_shiny_hue
    spot_hash shiny_leaf last_update_time legacy_data perma_faint
    original_max_level traded randomized forced_ability primal
    tradingCharmStatsIncreased expshare
  ].freeze
  OBJECT_FIELDS = { "Pokemon" => FIELDS,
                    "Move" => %w[id pp ppup],
                    "Owner" => %w[id name gender language],
                    "Mail" => %w[item message sender poke1 poke2 poke3] }.freeze
  CLASSES = { "Pokemon" => Pokemon, "Move" => Pokemon::Move,
              "Owner" => Pokemon::Owner, "Mail" => Mail }.freeze
  SHAPES = {
    "symbol" => %w[species status ability nature nature_for_stats item poke_ball forced_ability],
    "integer" => %w[form forced_form time_form_set exp level steps_to_hatch hp statusCount gender
                    ability_index cool beauty cute smart tough sheen pokerus happiness obtain_method
                    obtain_map obtain_level hatched_map timeReceived timeEggHatched personalID totalhp
                    attack defense spatk spdef speed previous_form saved_exp heart_gauge
                    heart_gauge_step_counter mirrorherb_steps cached_super_shiny_hue shiny_leaf
                    original_max_level evo_recoil_count evo_step_count],
    "boolean" => %w[shiny super_shiny shadow hyper_mode ready_to_evolve cannot_store
                    cannot_release cannot_trade perma_faint traded randomized
                    tradingCharmStatsIncreased expshare],
    "string" => %w[name obtain_text],
    "array" => %w[moves first_moves ribbons markings shadow_moves],
    "pairs" => %w[iv ivMaxed ev evo_move_count evo_crest_count saved_ev spot_hash legacy_data primal],
    "float" => %w[last_update_time],
    "Owner" => %w[owner], "Mail" => %w[mail], "Pokemon" => %w[fused]
  }.freeze
  raise "Unclassified trade field" unless (FIELDS - SHAPES.values.flatten).empty?
  SYMBOL_PATTERN = /\A[A-Za-z][A-Za-z0-9_]{0,63}\z/
  STATS = %i[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze

  def self.effective(pokemon)
    { "types" => pokemon.types.map(&:to_s),
      "base_stats" => STATS.map { |stat| pokemon.baseStats.fetch(stat) },
      "ability" => pokemon.ability_id&.to_s,
      "stats" => [pokemon.totalhp, pokemon.attack, pokemon.defense,
                  pokemon.spatk, pokemon.spdef, pokemon.speed] }
  end

  def self.pack(pokemon)
    raise ArgumentError, "Not a Pokémon" unless pokemon.instance_of?(Pokemon)
    # Several native getters lazily cache values. Evaluate on a trusted local
    # copy so building an offer never changes the player's live Pokémon.
    behavior = effective(Marshal.load(Marshal.dump(pokemon)))
    value = { "version" => VERSION, "pokemon" => encode(pokemon), "effective" => behavior }
    validate(value)
    value
  end

  def self.unpack(value)
    validate(value)
    pokemon = decode(value.fetch("pokemon"))
    raise ArgumentError, "Pokémon changed on reconstruction" unless pack(pokemon) == value
    pokemon
  end

  def self.validate(value)
    raise ArgumentError, "Invalid trade data version" unless value.is_a?(Hash) &&
      value.keys.sort == %w[effective pokemon version] && value["version"] == VERSION
    json = JSON.generate(value)
    raise ArgumentError, "Trade data too large" if json.bytesize > MAX_BYTES
    count = [0]
    check_node(value["pokemon"], 0, count)
    behavior = value["effective"]
    raise ArgumentError, "Invalid effective attributes" unless behavior.is_a?(Hash) &&
      behavior.keys.sort == %w[ability base_stats stats types] &&
      behavior["types"].is_a?(Array) && behavior["types"].length.between?(1, 2) &&
      behavior["types"].all? { |t| t.is_a?(String) && GameData::Type.exists?(t) } &&
      behavior["base_stats"].is_a?(Array) && behavior["base_stats"].length == 6 &&
      behavior["base_stats"].all? { |n| n.is_a?(Integer) && n.between?(1, 1000) } &&
      behavior["stats"].is_a?(Array) && behavior["stats"].length == 6 &&
      behavior["stats"].all? { |n| n.is_a?(Integer) && n.between?(1, 100_000) } &&
      (behavior["ability"].nil? ||
       (behavior["ability"].is_a?(String) && GameData::Ability.exists?(behavior["ability"])))
    pokemon = value["pokemon"]
    raise ArgumentError, "Invalid Pokémon record" unless pokemon["class"] == "Pokemon"
    fields = pokemon["fields"]
    fields.each do |key, raw|
      kind = SHAPES.find { |_shape, names| names.include?(key) }&.first
      valid = raw.nil? || case kind
                          when "symbol" then raw.is_a?(Hash) && raw.keys == ["symbol"]
                          when "integer" then raw.is_a?(Integer)
                          when "boolean" then raw == true || raw == false
                          when "string" then raw.is_a?(String)
                          when "array" then raw.is_a?(Hash) && raw.keys == ["array"]
                          when "pairs" then raw.is_a?(Hash) && raw.keys == ["pairs"]
                          when "float" then raw.is_a?(Integer) || raw.is_a?(Float)
                          else raw.is_a?(Hash) && raw["class"] == kind
                          end
      raise ArgumentError, "Invalid field type: #{key}" unless valid
    end
    species = symbol_field(fields, "species", GameData::Species)
    form = number_field(fields, "form", 0, 999)
    raise ArgumentError, "Unknown species form" unless GameData::Species.get_species_form(species, form)
    number_field(fields, "personalID", 0, 0xffffffff)
    number_field(fields, "exp", 0, 10**10)
    number_field(fields, "hp", 0, 100_000)
    number_field(fields, "steps_to_hatch", 0, 1_000_000)
    number_field(fields, "happiness", 0, 255)
    number_field(fields, "pokerus", 0, 255)
    number_field(fields, "statusCount", 0, 1000)
    number_field(fields, "shiny_leaf", 0, 6) if fields.key?("shiny_leaf")
    number_field(fields, "totalhp", 1, 100_000)
    raise ArgumentError, "HP exceeds maximum" if fields["hp"] > fields["totalhp"]
    if fields.key?("level") && !fields["level"].nil?
      number_field(fields, "level", 1, GameData::GrowthRate.max_level)
    end
    if fields.key?("gender") && !fields["gender"].nil?
      number_field(fields, "gender", 0, 1)
    end
    %w[shiny super_shiny perma_faint randomized traded expshare].each do |key|
      value = fields[key]
      raise ArgumentError, "Invalid #{key}" unless value.nil? || value == true || value == false
    end
    symbol_field(fields, "status", GameData::Status)
    symbol_field(fields, "poke_ball", GameData::Item)
    %w[ability forced_ability].each { |f| symbol_field(fields, f, GameData::Ability, true) }
    %w[nature nature_for_stats].each { |f| symbol_field(fields, f, GameData::Nature, true) }
    symbol_field(fields, "item", GameData::Item, true)
    %w[iv ev].each do |key|
      values = decode(fields.fetch(key))
      raise ArgumentError, "Invalid #{key}" unless values.is_a?(Hash)
      expected = []
      GameData::Stat.each_main { |stat| expected << stat.id }
      raise ArgumentError, "Incomplete #{key}" unless (expected - values.keys).empty? &&
        (values.keys - expected).empty?
      limit = key == "iv" ? Pokemon::IV_STAT_LIMIT : Pokemon::EV_STAT_LIMIT
      raise ArgumentError, "Invalid #{key} values" unless values.values.all? { |v| v.is_a?(Integer) && v.between?(0, limit) }
      raise ArgumentError, "EV total too high" if key == "ev" && values.values.sum > Pokemon::EV_LIMIT
    end
    maxed = decode(fields.fetch("ivMaxed"))
    raise ArgumentError, "Invalid hyper training" unless maxed.is_a?(Hash) &&
      maxed.keys.all? { |k| GameData::Stat.exists?(k) } &&
      maxed.values.all? { |v| v == true || v == false }
    %w[first_moves ribbons].each do |key|
      values = decode(fields.fetch(key))
      registry = key == "first_moves" ? GameData::Move : GameData::Ribbon
      raise ArgumentError, "Invalid #{key}" unless values.is_a?(Array) && values.length <= 1000 &&
        values.all? { |v| v.is_a?(Symbol) && registry.exists?(v) }
    end
    markings = decode(fields.fetch("markings"))
    raise ArgumentError, "Invalid markings" unless markings.is_a?(Array) && markings.length <= 32 &&
      markings.all? { |v| v.is_a?(Integer) && v.between?(0, 15) }
    %w[evo_move_count evo_crest_count saved_ev].each do |key|
      next unless fields.key?(key) && fields[key]
      values = decode(fields[key])
      registry = key == "evo_move_count" ? GameData::Move :
                 key == "evo_crest_count" ? GameData::Item : GameData::Stat
      raise ArgumentError, "Invalid #{key}" unless values.is_a?(Hash) && values.length <= 1000 &&
        values.all? { |id, count| id.is_a?(Symbol) && registry.exists?(id) &&
          count.is_a?(Integer) && count.between?(0, 10_000) }
    end
    if fields.key?("shadow_moves") && fields["shadow_moves"]
      shadow_moves = decode(fields["shadow_moves"])
      raise ArgumentError, "Invalid shadow moves" unless shadow_moves.is_a?(Array) &&
        shadow_moves.length <= 2 * Pokemon::MAX_MOVES &&
        shadow_moves.all? { |id| id.nil? || (id.is_a?(Symbol) && GameData::Move.exists?(id)) }
    end
    if fields.key?("legacy_data") && fields["legacy_data"]
      legacy = decode(fields["legacy_data"])
      allowed = %i[party_time item_count move_count egg_count trade_count defeated_count
                   fainted_count supereff_count critical_count retreat_count trainer_count
                   leader_count legend_count champion_count loss_count]
      raise ArgumentError, "Invalid Legacy Data" unless legacy.is_a?(Hash) &&
        (legacy.keys - allowed).empty? && legacy.all? { |k, v|
          k == :party_time ? v.is_a?(Numeric) && v.finite? && v.between?(0, 10**12) :
                             v.is_a?(Integer) && v.between?(0, 10**9) }
    end
    moves = fields.fetch("moves")
    raise ArgumentError, "Invalid moves" unless moves.is_a?(Hash) &&
      moves["array"].is_a?(Array) && moves["array"].length <= Pokemon::MAX_MOVES
    moves["array"].each do |move|
      raise ArgumentError, "Invalid move record" unless move.is_a?(Hash) && move["class"] == "Move"
      id = symbol_field(move["fields"], "id", GameData::Move)
      ppup = number_field(move["fields"], "ppup", 0, 3)
      pp = number_field(move["fields"], "pp", 0, 99)
      max_pp = GameData::Move.get(id).total_pp
      raise ArgumentError, "Invalid remaining PP" if pp > max_pp + max_pp * ppup / 5
    end
    owner = fields.fetch("owner")
    raise ArgumentError, "Invalid owner" unless owner.is_a?(Hash) && owner["class"] == "Owner"
    number_field(owner["fields"], "id", 0, 0xffffffff)
    number_field(owner["fields"], "gender", 0, 2)
    number_field(owner["fields"], "language", 0, 255)
    raise ArgumentError, "Invalid owner name" unless owner["fields"]["name"].is_a?(String) &&
      owner["fields"]["name"].bytesize <= 100
    if fields["mail"]
      mail = fields["mail"]
      raise ArgumentError, "Invalid mail" unless mail.is_a?(Hash) && mail["class"] == "Mail"
      symbol_field(mail["fields"], "item", GameData::Item)
      raise ArgumentError, "Mail item does not match held item" unless
        fields["item"] == mail["fields"]["item"]
      %w[message sender].each do |key|
        text = mail["fields"][key]
        raise ArgumentError, "Invalid mail #{key}" unless text.is_a?(String) &&
          text.bytesize <= (key == "message" ? 1000 : 100)
      end
      %w[poke1 poke2 poke3].each do |key|
        next if mail["fields"][key].nil?
        icon = decode(mail["fields"][key])
        raise ArgumentError, "Invalid mail portrait" unless icon.is_a?(Array) &&
          icon.length.between?(5, 6) && icon[0].is_a?(Symbol) &&
          GameData::Species.exists?(icon[0]) && [0, 1].include?(icon[1]) &&
          [true, false].include?(icon[2]) && icon[3].is_a?(Integer) &&
          icon[3].between?(0, 999) && [true, false].include?(icon[4]) &&
          (icon.length == 5 || icon[5] == true)
      end
    end
    if fields["fused"]
      fused = fields["fused"]
      raise ArgumentError, "Invalid fusion" unless fused.is_a?(Hash) && fused["class"] == "Pokemon" &&
        fused["fields"]["fused"].nil?
      # A fused Pokémon is bounded to one extra level and validated separately.
      nested = decode(fused)
      validate("version" => VERSION, "pokemon" => fused, "effective" => effective(nested))
    end
    true
  end

  def self.number_field(fields, key, low, high)
    value = fields.fetch(key)
    raise ArgumentError, "Invalid #{key}" unless value.is_a?(Integer) && value.between?(low, high)
    value
  end

  def self.symbol_field(fields, key, registry, nullable = false)
    value = fields[key]
    return nil if nullable && value.nil?
    raise ArgumentError, "Invalid #{key}" unless value.is_a?(Hash) && value.keys == ["symbol"] &&
      value["symbol"].is_a?(String) && SYMBOL_PATTERN.match?(value["symbol"]) &&
      registry.exists?(value["symbol"])
    value["symbol"].to_sym
  end

  def self.encode(value, depth = 0, seen = {})
    raise ArgumentError, "Trade record too deep" if depth > MAX_DEPTH
    case value
    when NilClass, TrueClass, FalseClass, Integer
      value
    when Float
      raise ArgumentError, "Non-finite number" unless value.finite?
      value
    when String
      raise ArgumentError, "Invalid text" unless value.valid_encoding? && value.bytesize <= 1024
      value.dup
    when Symbol
      name = value.to_s
      raise ArgumentError, "Invalid symbol" unless SYMBOL_PATTERN.match?(name)
      { "symbol" => name }
    when Array
      raise ArgumentError, "Array too large" if value.length > MAX_ELEMENTS
      value.map { |v| encode(v, depth + 1, seen) }.then { |v| { "array" => v } }
    when Hash
      raise ArgumentError, "Hash too large" if value.length > MAX_ELEMENTS
      { "pairs" => value.map { |k, v| [encode(k, depth + 1, seen), encode(v, depth + 1, seen)] } }
    else
      klass = CLASSES.find { |_name, c| value.instance_of?(c) }&.first
      raise ArgumentError, "Unsupported Pokémon attribute #{value.class}" unless klass
      raise ArgumentError, "Cyclic Pokémon data" if seen[value.object_id]
      seen[value.object_id] = true
      allowed = OBJECT_FIELDS.fetch(klass)
      fields = value.instance_variables.to_h do |ivar|
        name = ivar.to_s.delete_prefix("@")
        raise ArgumentError, "Unknown #{klass} field #{name}" unless allowed.include?(name)
        [name, encode(value.instance_variable_get(ivar), depth + 1, seen)]
      end
      seen.delete(value.object_id)
      { "class" => klass, "fields" => fields }
    end
  end

  def self.check_node(node, depth, count)
    count[0] += 1
    raise ArgumentError, "Trade record too complex" if count[0] > MAX_ELEMENTS || depth > MAX_DEPTH
    case node
    when NilClass, TrueClass, FalseClass, Integer
      raise ArgumentError, "Integer too large" if node.is_a?(Integer) && node.abs > 10**15
    when Float
      raise ArgumentError, "Non-finite number" unless node.finite?
    when String
      raise ArgumentError, "Invalid text" unless node.valid_encoding? && node.bytesize <= 1024
    when Hash
      if node.keys == ["symbol"]
        raise ArgumentError, "Invalid symbol" unless node["symbol"].is_a?(String) && SYMBOL_PATTERN.match?(node["symbol"])
      elsif node.keys == ["array"]
        raise ArgumentError, "Invalid array" unless node["array"].is_a?(Array)
        node["array"].each { |v| check_node(v, depth + 1, count) }
      elsif node.keys == ["pairs"]
        raise ArgumentError, "Invalid pairs" unless node["pairs"].is_a?(Array)
        node["pairs"].each do |pair|
          raise ArgumentError, "Invalid pair" unless pair.is_a?(Array) && pair.length == 2 &&
            [NilClass, String, Integer, Hash].any? { |c| pair[0].is_a?(c) }
          pair.each { |v| check_node(v, depth + 1, count) }
        end
      elsif node.keys.sort == %w[class fields]
        klass = node["class"]
        fields = node["fields"]
        raise ArgumentError, "Unknown record class" unless OBJECT_FIELDS.key?(klass) && fields.is_a?(Hash) &&
          (fields.keys - OBJECT_FIELDS[klass]).empty? && fields.keys.all? { |k| k.is_a?(String) }
        required = { "Pokemon" => %w[species form exp hp status statusCount moves owner personalID
                                     totalhp happiness pokerus poke_ball steps_to_hatch],
                     "Move" => %w[id pp ppup], "Owner" => %w[id name gender language],
                     "Mail" => %w[item message sender poke1 poke2 poke3] }
        raise ArgumentError, "Incomplete #{klass} record" unless (required.fetch(klass) - fields.keys).empty?
        fields.each_value { |v| check_node(v, depth + 1, count) }
      else
        raise ArgumentError, "Unexpected record structure"
      end
    else
      raise ArgumentError, "Unsupported record value"
    end
  end

  def self.decode(node)
    case node
    when Hash
      return node["symbol"].to_sym if node.key?("symbol")
      return node["array"].map { |v| decode(v) } if node.key?("array")
      if node.key?("pairs")
        result = {}
        node["pairs"].each do |k, v|
          key = decode(k)
          raise ArgumentError, "Repeated map key" if result.key?(key)
          result[key] = decode(v)
        end
        return result
      end
      klass = CLASSES.fetch(node.fetch("class"))
      object = klass.allocate
      node.fetch("fields").each { |k, v| object.instance_variable_set("@#{k}", decode(v)) }
      object
    else
      node
    end
  end
end
