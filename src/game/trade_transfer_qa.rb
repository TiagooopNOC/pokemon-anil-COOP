# Opt-in two-engine protocol test using disposable save copies. No OS input.
require "digest"
require "fileutils"
module AnilCoopTradeTransferQA
  SLOT = "Partida 900001"
  CODE = "ABCDEFGHJKLM"

  def self.wait(seconds = 45)
    deadline = Time.now.to_f + seconds
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      return if yield
      raise "trade transfer QA timeout" if Time.now.to_f >= deadline
    end
  end

  def self.state(txid)
    (AnilCoop.instance_variable_get(:@trade_sessions) || {})[txid]
  end

  def self.run
    if ENV["ANIL_COOP_TRADE_TRANSFER_QA"] == "reload"
      prior_path = File.join(AnilCoopDev::PROFILE, "qa-trade-transfer-previous.json")
      prior = JSON.parse(File.read(prior_path))
      raise "previous transfer did not pass" unless prior["pass"]
      data = SaveData.get_data_from_file(SaveData.get_full_path(SLOT))
      SaveData.load_bootup_values(data)
      Game.load(data)
      pokemon = $player.party[0]
      receipt = $PokemonGlobal.anil_coop_trade_receipts&.fetch(prior["transaction"])
      raise "trade receipt missing after reload" unless receipt &&
        receipt["received"] == [pokemon.owner.id, pokemon.personalID]
      raise "wrong Pokémon after reload" unless AnilCoop.pokemon_key(pokemon) == prior["received"]
      original = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
      original_hash = Digest::SHA256.file(original).hexdigest
      raise "game save failed after trade" unless Game.save(SLOT)
      saved = SaveData.get_data_from_file(SaveData.get_full_path(SLOT))
      raise "trade lost on normal save" unless
        AnilCoop.pokemon_key(saved[:player].party[0]) == prior["received"] &&
        saved[:global_metadata].anil_coop_trade_receipts&.key?(prior["transaction"])
      raise "original QA save changed" unless Digest::SHA256.file(original).hexdigest == original_hash
      result = { pass: true, role: "reload", received: AnilCoop.pokemon_key(pokemon),
                 receipt: true, normal_save: true, transaction: prior["transaction"] }
      return
    end
    role = ENV.fetch("ANIL_COOP_ONLINE_QA_ROLE")
    original = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    copy = SaveData.get_full_path(SLOT)
    raise "disposable QA slot already exists" if File.exist?(copy)
    original_hash = Digest::SHA256.file(original).hexdigest
    FileUtils.cp(original, copy)
    data = SaveData.get_data_from_file(copy)
    SaveData.load_bootup_values(data)
    Game.load(data)
    $player.save_slot = SLOT
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    raise "no tradable QA Pokémon" unless AnilCoop.trade_eligible?($player.party[0])
    gave = AnilCoop.pokemon_key($player.party[0])
    if role == "create"
      AnilCoop.menu_start("create", "127.0.0.1", CODE, name: "client03")
    else
      begin
        AnilCoop.menu_start("join", "127.0.0.1", CODE, name: "client04")
      rescue StandardError
        sleep 0.5
        retry if (@attempts = (@attempts || 0) + 1) < 10
        raise
      end
    end
    AnilCoop.instance_variable_set(:@trade_modal, true)
    AnilCoop.instance_variable_set(:@invite_modal, true)
    wait { AnilCoop.instance_variable_get(:@peers).length == 1 }
    if role == "create"
      peer = AnilCoop.instance_variable_get(:@peers).keys.first
      AnilCoop.queue(type: "invite_request", request: "f" * 16, target: peer, kind: "trade")
    else
      wait { !(AnilCoop.instance_variable_get(:@incoming_invites) || {}).empty? }
      AnilCoop.queue(type: "invite_reply", request: "f" * 16, accept: true)
    end
    wait { (AnilCoop.instance_variable_get(:@trade_sessions) || {}).values.any? { |s| s["phase"] == "choosing" } }
    txid = AnilCoop.instance_variable_get(:@trade_sessions).keys.first
    screen = AnilCoopTradeScreen.new(txid)
    screen.instance_variable_set(:@local_slot, 0)
    AnilCoop.queue(type: "trade_offer", trade: txid,
                   offer: AnilCoop.trade_preview_snapshot($player.party[0], 0))
    wait { state(txid) && state(txid)["offers"].length == 2 }
    AnilCoop.queue(type: "trade_confirm", trade: txid, version: state(txid)["version"])
    wait { state(txid) && state(txid)["phase"] == "payloads" }
    screen.publish_payload(state(txid))
    wait { state(txid) && state(txid)["phase"] == "preparing" }
    screen.prepare_local(state(txid))
    wait { state(txid) && state(txid)["phase"] == "commit" }
    screen.apply_local(state(txid))
    wait { state(txid) && state(txid)["phase"] == "complete" }
    screen.finish_local
    raise "original QA save changed" unless Digest::SHA256.file(original).hexdigest == original_hash
    committed = SaveData.get_data_from_file(copy)
    received = committed[:player].party[0]
    receipt = committed[:global_metadata].anil_coop_trade_receipts&.fetch(txid)
    raise "received same Pokémon" if AnilCoop.pokemon_key(received) == gave
    raise "receipt missing" unless receipt && receipt["gave"].join(":") == gave &&
      receipt["received"] == [received.owner.id, received.personalID]
    result = { pass: true, role: role, transaction: txid, gave: gave,
               received: AnilCoop.pokemon_key(received), species: received.species.to_s,
               receipt: true, original_save_unchanged: true,
               save_hash: Digest::SHA256.file(copy).hexdigest }
  rescue StandardError => e
    result = { pass: false, role: role, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(8) }
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-trade-transfer-result.json"), JSON.generate(result))
    exit
  end
end

$anil_trade_transfer_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_trade_transfer_trace.disable
  AnilCoopTradeTransferQA.run
end
$anil_trade_transfer_trace.enable
