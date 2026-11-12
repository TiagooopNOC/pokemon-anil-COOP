# Opt-in, local-only round-trip test against the loaded game and isolated QA save.
require "digest"
module AnilCoopTradeDataQA
  def self.roundtrip(pokemon, label)
    before = pokemon.instance_variables.sort.to_h { |iv| [iv, Marshal.dump(pokemon.instance_variable_get(iv))] }
    encoded = AnilCoopTradeData.pack(pokemon)
    reconstructed = AnilCoopTradeData.unpack(JSON.parse(JSON.generate(encoded)))
    after = reconstructed.instance_variables.sort.to_h { |iv| [iv, Marshal.dump(reconstructed.instance_variable_get(iv))] }
    raise "#{label}: instance variables changed" unless before == after
    raise "#{label}: encoded data changed" unless encoded == AnilCoopTradeData.pack(reconstructed)
    { name: label, bytes: JSON.generate(encoded).bytesize, fields: before.length }
  end

  def self.run
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    original_hash = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    cases = []
    $player.party.each_with_index { |p, i| cases << roundtrip(p, "saved_party_#{i}") }
    p = Pokemon.new(:BULBASAUR, 12, $player, true, false, false)
    p.moves.first.pp = [p.moves.first.pp - 2, 0].max
    p.item = :POTION
    p.shiny = true
    p.super_shiny = true
    p.shiny_leaf = 2
    p.legacy_data[:trade_count] = 3
    p.forced_ability = p.ability_id if p.respond_to?(:forced_ability=)
    p.randomized = true if p.respond_to?(:randomized=)
    p.traded = true if p.respond_to?(:traded=)
    p.expshare = true if p.respond_to?(:expshare=)
    cases << roundtrip(p, "special_attributes")
    spinda = Pokemon.new(:SPINDA, 14, $player, true, false, false)
    spinda.spot_hash = { 0 => [[[1, 2], 3, 4, 5, 6]] } if spinda.respond_to?(:spot_hash=)
    cases << roundtrip(spinda, "spinda_pattern")
    mixed = Pokemon.new(:SQUIRTLE, 16, $player, true, false, false)
    mixed.fused = Pokemon.new(:CHARMANDER, 11, $player, true, false, false)
    mixed.instance_variable_set(:@perma_faint, true)
    mixed.instance_variable_set(:@original_max_level, 50)
    mixed.instance_variable_set(:@mirrorherb_steps, 5)
    cases << roundtrip(mixed, "fusion_and_challenge_metadata")
    letter = Pokemon.new(:BULBASAUR, 8, $player, true, false, false)
    letter.item = :GRASSMAIL
    letter.mail = Mail.new(:GRASSMAIL, "Prueba QA", "Amigo",
                           [:BULBASAUR, 0, false, 0, false])
    cases << roundtrip(letter, "mail_and_portrait")
    altered = AnilCoopTradeData.pack(p)
    altered["pokemon"]["fields"]["unexpected_extension"] = true
    begin
      AnilCoopTradeData.unpack(altered)
      raise "unknown field accepted"
    rescue ArgumentError
    end
    nested_object = AnilCoopTradeData.pack(p)
    nested_object["pokemon"]["fields"]["legacy_data"]["pairs"] <<
      [{ "symbol" => "unexpected" }, nested_object["pokemon"]["fields"]["owner"]]
    begin
      AnilCoopTradeData.unpack(nested_object)
      raise "object embedded in metadata accepted"
    rescue ArgumentError
    end
    incompatible = AnilCoopTradeData.pack(p)
    incompatible["effective"]["base_stats"][0] += 1
    begin
      AnilCoopTradeData.unpack(incompatible)
      raise "incompatible effective stats accepted"
    rescue ArgumentError
    end
    unknown = Pokemon.new(:BULBASAUR, 5, $player, true, false, false)
    unknown.instance_variable_set(:@future_plugin_field, 123)
    begin
      AnilCoopTradeData.pack(unknown)
      raise "future plugin field silently omitted"
    rescue ArgumentError
    end
    malformed = AnilCoopTradeData.pack(p)
    malformed["pokemon"]["fields"]["moves"]["array"][0]["fields"]["pp"] = 999
    begin
      AnilCoopTradeData.unpack(malformed)
      raise "invalid PP accepted"
    rescue ArgumentError
    end
    raise "QA save changed" unless Digest::SHA256.file(save).hexdigest == original_hash
    result = { pass: true, cases: cases, invalid_field_rejected: true,
               unknown_local_field_rejected: true, invalid_pp_rejected: true,
               incompatible_effective_stats_rejected: true,
               nested_object_rejected: true,
               save_unchanged: true }
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(7) }
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-trade-data-result.json"), JSON.generate(result))
    exit
  end
end

$anil_trade_data_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_trade_data_trace.disable
  AnilCoopTradeDataQA.run
end
$anil_trade_data_trace.enable
