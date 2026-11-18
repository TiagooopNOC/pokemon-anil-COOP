# Opt-in QA: creates a disposable copy of an isolated save. It never replaces
# Partida 1 or any personal save and never sends a trade over the network.
require "fileutils"
module AnilCoopTradeCandidateQA
  TXID = "d" * 32
  SLOT = "Partida 900001"

  def self.run
    original_path = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    test_path = SaveData.get_full_path(SLOT)
    mode = ENV["ANIL_COOP_TRADE_CANDIDATE_QA"]
    if mode == "create"
      raise "QA slot already exists" if File.exist?(test_path)
      original_hash = Digest::SHA256.file(original_path).hexdigest
      data = SaveData.get_data_from_file(original_path)
      SaveData.load_bootup_values(data)
      Game.load(data)
      raise "QA party has no eligible Pokémon" unless AnilCoop.trade_eligible?($player.party[0])
      FileUtils.cp(original_path, test_path)
      old_slot = $player.save_slot
      $player.save_slot = SLOT
      begin
        own = AnilCoopTradeData.pack($player.party[0])
        foreign_owner = Pokemon::Owner.new(1_234_567_890, "RemoteQA", 1, 2)
        incoming = Pokemon.new(:SQUIRTLE, 11, foreign_owner, true, false, false)
        incoming.item = :POTION
        incoming.moves.first.pp = [incoming.moves.first.pp - 2, 0].max
        theirs = AnilCoopTradeData.pack(incoming)
        details = AnilCoopTradeCandidate.create(TXID, 0, own, theirs)
      ensure
        $player.save_slot = old_slot
      end
      raise "QA original save changed" unless Digest::SHA256.file(original_path).hexdigest == original_hash
      raise "QA copy changed before commit" unless Digest::SHA256.file(test_path).hexdigest == details["before_hash"]
      result = { pass: true, mode: mode, trade: TXID, candidate: details,
                 original_hash: original_hash, original_party_key: AnilCoop.pokemon_key($player.party[0]),
                 incoming_key: AnilCoop.pokemon_key(incoming) }
    elsif mode == "reload"
      raise "QA copy not committed" unless File.file?(test_path)
      data = SaveData.get_data_from_file(test_path)
      receipt = data.fetch(:global_metadata).anil_coop_trade_receipts&.fetch(TXID)
      pokemon = data.fetch(:player).party[0]
      raise "Missing committed receipt" unless receipt && receipt["received"] ==
        [pokemon.owner.id, pokemon.personalID]
      raise "Transferred Pokémon damaged" unless pokemon.owner.name == "RemoteQA" &&
        pokemon.species == :SQUIRTLE && pokemon.item_id == :POTION && pokemon.moves.first.pp >= 0
      result = { pass: true, mode: mode, receipt: true,
                 species: pokemon.species.to_s, owner: pokemon.owner.name,
                 original_hash_unchanged: true }
    else
      raise "Invalid QA mode"
    end
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(7) }
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-trade-candidate-result.json"), JSON.generate(result))
    exit
  end
end

$anil_trade_candidate_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_trade_candidate_trace.disable
  AnilCoopTradeCandidateQA.run
end
$anil_trade_candidate_trace.enable
