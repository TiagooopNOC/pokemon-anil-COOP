# Opt-in two-engine check. It never writes a save or transfers a Pokémon.
require "digest"
module AnilCoopTradePreviewQA
  def self.wait(seconds = 25)
    deadline = Time.now.to_f + seconds
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      return if yield
      raise "trade preview QA deadline" if Time.now.to_f >= deadline
    end
  end

  def self.run
    File.write(File.join(AnilCoopDev::PROFILE, "qa-trade-stages.log"), "")
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    role = ENV.fetch("ANIL_COOP_ONLINE_QA_ROLE")
    $game_temp.in_menu = true if role == "join"
    code = "ABCDEFGHJKLM"
    name = role == "create" ? "client03" : "client04"
    if role == "create"
      AnilCoop.menu_start("create", "127.0.0.1", code, name: name)
    else
      begin
        AnilCoop.menu_start("join", "127.0.0.1", code, name: name)
      rescue StandardError
        sleep 1
        retry if (@attempts = (@attempts || 0) + 1) < 8
        raise
      end
    end
    wait { AnilCoop.instance_variable_get(:@peers).length == 1 }
    if role == "create"
      peer = AnilCoop.instance_variable_get(:@peers).keys.first
      AnilCoop.queue(type: "invite_request", request: "e" * 16,
                     target: peer, kind: "trade")
    end
    if role == "join"
      $anil_trade_qa_online_screen = true
      AnilCoop.online_menu
      $anil_trade_qa_online_screen = false
      $game_temp.in_menu = false
    end
    wait(35) { $anil_trade_qa_terminal_phase && !AnilCoop.instance_variable_get(:@trade_modal) }
    raise "preview did not reach both confirmations" unless $anil_trade_qa_terminal_phase == "preview_complete"
    raise "native party not opened" unless $anil_trade_qa_party_seen
    raise "both offers not displayed" unless $anil_trade_qa_both_offers
    raise "remote summary not opened" if role == "create" && !$anil_trade_qa_summary_seen
    raise "party changed in save" unless Digest::SHA256.file(save).hexdigest == before
    result = { pass: true, role: role, native_party: true, both_offers: true,
               native_summary: !!$anil_trade_qa_summary_seen,
               double_confirm_preview: true, transfer_enabled: false,
               save_unchanged: true }
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(7) }
  ensure
    $game_temp.in_menu = false if $game_temp
    AnilCoop.menu_stop rescue nil
    File.write(File.join(AnilCoopDev::PROFILE, "qa-trade-preview-result.json"), JSON.generate(result))
    exit
  end
end

module AnilCoopTradeQAParty
  def pbStartScene(*args)
    result = super
    unless $anil_trade_qa_party_seen
      bitmap = Graphics.snap_to_bitmap
      bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-trade-party.png"))
      bitmap.dispose
    end
    $anil_trade_qa_party_seen = true
    result
  end
  def pbChoosePokemon; 0; end
  def pbShowCommands(*_args); 0; end
end
AnilCoopRemotePartyScene.prepend(AnilCoopTradeQAParty)

module AnilCoopTradeQASummary
  def pbStartScene(*args)
    result = super
    $anil_trade_qa_summary_active = true
    $anil_trade_qa_summary_seen = true
    result
  end
  def pbEndScene
    $anil_trade_qa_summary_active = false
    super
  end
end
AnilCoopRemoteSummaryScene.prepend(AnilCoopTradeQASummary)

module AnilCoopTradeQAScreen
  def qa_stage(value)
    File.open(File.join(AnilCoopDev::PROFILE, "qa-trade-stages.log"), "a") do |file|
      file.puts("#{Time.now.utc} #{ENV['ANIL_COOP_ONLINE_QA_ROLE']} #{value}")
    end
  end

  def draw
    super
    unless @anil_qa_offer_sent
      @anil_qa_offer_sent = true
      qa_stage("select_offer")
      select_offer
      qa_stage("offer_sent")
      return
    end
    current = state
    return unless current && offers[@my_id] && offers[peer_id]
    unless $anil_trade_qa_both_offers
      bitmap = Graphics.snap_to_bitmap
      bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-trade-confirm.png"))
      bitmap.dispose
      $anil_trade_qa_both_offers = true
    end
    return if @anil_qa_confirm_sent
    @anil_qa_confirm_sent = true
    if ENV["ANIL_COOP_ONLINE_QA_ROLE"] == "create"
      qa_stage("inspect_remote")
      inspect_offer(offers[peer_id], peer_id)
      qa_stage("inspected_remote")
    end
    $anil_trade_qa_confirm = true
    $anil_trade_qa_up_sent = false
    qa_stage("confirm")
    confirm
    qa_stage("confirmed")
    $anil_trade_qa_confirm = false
  end
end
AnilCoopTradeScreen.prepend(AnilCoopTradeQAScreen)

module AnilCoopTradeQAInput
  def repeat?(key)
    if key == Input::UP && $anil_trade_qa_confirm && !$anil_trade_qa_up_sent
      $anil_trade_qa_up_sent = true
      return true
    end
    super
  end
  def trigger?(key)
    return true if key == Input::BACK && $anil_trade_qa_summary_active
    if key == Input::BACK && $anil_trade_qa_online_screen
      return $anil_trade_qa_terminal_seen &&
             !AnilCoop.instance_variable_get(:@trade_modal) &&
             !AnilCoop.instance_variable_get(:@invite_modal)
    end
    if $anil_trade_qa_confirm
      return false if key == Input::BACK
      return true if key == Input::USE && $anil_trade_qa_up_sent
    end
    if key == Input::USE && AnilCoop.instance_variable_get(:@invite_modal)
      return true
    end
    if key == Input::USE && AnilCoop.instance_variable_get(:@trade_modal)
      trade = AnilCoop.instance_variable_get(:@trade_pending)
      state = (AnilCoop.instance_variable_get(:@trade_sessions) || {})[trade]
      if state && state["phase"] != "choosing"
        $anil_trade_qa_terminal_phase = state["phase"]
        $anil_trade_qa_terminal_seen = true
        return true
      end
    end
    super
  end
end
Input.singleton_class.prepend(AnilCoopTradeQAInput)

$anil_trade_qa_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_trade_qa_trace.disable
  AnilCoopTradePreviewQA.run
end
$anil_trade_qa_trace.enable
