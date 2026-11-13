module AnilPvpQaMessages
  def pbDisplayPausedMessage(message); pbDisplayMessage(message); end
  def pbDisplayMessage(message, brief = false, &block); AnilCoop.log("PvP QA text #{message}"); block&.call; end
end
Battle::Scene.prepend(AnilPvpQaMessages)
class AnilCoopDuel
  def choose_local_order
    AnilCoop.log("PvP QA input #{@turnCount}")
    return ["none", 0, -1] unless pbCanShowCommands?(0)
    if ENV["ANIL_PVP_QA_MODE"] == "disconnect" && @client_id == 1 && @turnCount >= 1
      AnilCoop.disconnect
      raise AnilCoop::BattleStopped, 'QA transport closed'
    end
    if ENV["ANIL_PVP_QA_MODE"] == "switch" && @turnCount == 0 && @client_id == 1
      return ["switch", 1, -1]
    end
    return ["move", 1, -1] if @turnCount == 1
    ["move", 0, -1]
  end
  def pbPartyScreen(index, *args)
    (0...pbParty(index).length).find { |slot| pbCanSwitchIn?(index, slot) } || -1
  end
  def pbDisplayPaused(message, &block); @scene.pbDisplayMessage(message, &block); end
end

module AnilPvpQaSelection
  def pbChoosePokemon(*)
    @qa_slot = @qa_slot ? @qa_slot + 1 : 0
    return @qa_slot if @qa_slot < $player.party.length
    Graphics.update
    bitmap = Graphics.snap_to_bitmap
    bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-pvp-selection.png"))
    max_party_size
  ensure
    bitmap&.dispose
  end

  def pbShowCommands(*); 0; end
end
AnilCoopTeamScene.prepend(AnilPvpQaSelection)
trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  trace.disable
  report = {}
  begin
    mode, role = ENV.values_at("ANIL_PVP_QA_MODE","ANIL_COOP_MODE")
    save = SaveData.get_full_path("Partida 1")
    if !File.exist?(save)
      Game.start_new
      $player.name = ENV.fetch("ANIL_COOP_NAME")
      raise "fixture save failed" unless Game.save("Partida 1")
    else
      data = SaveData.get_data_from_file(save)
      SaveData.load_bootup_values(data)
      Game.load(data)
    end
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    before = Digest::SHA256.file(save).hexdigest
    count = mode == "switch" ? 2 : 1
    strong = mode == "guest" ? role == "join" : role == "create"
    $player.party = Array.new(count) do |i|
      p = AnilCoop.test_pokemon(:BULBASAUR, $player, (role == "create" ? 10 : 20) + i, [:TACKLE,:GROWL], :OVERGROW)
      p.level = strong ? 14 : 10
      p.calc_stats
      p.heal
      p.item = :ORANBERRY if mode == "switch"
      p
    end
    original = [$player, $PokemonGlobal, $bag, $stats]
    party = $player.party.each_with_index.map { |p, i| AnilCoop.team_snapshot(p, i) }
    AnilCoop.instance_variable_set(:@qa_pvp,true)
    wait = proc do |&condition|
      deadline = System.uptime + 35
      until condition.call
        AnilCoop.battle_tick
        Graphics.update
        Input.update
        raise "QA deadline" if System.uptime >= deadline
      end
    end
    wait.call { AnilCoop.connected? && !AnilCoop.instance_variable_get(:@peers).empty? }
    if role == "create"
      peer = AnilCoop.instance_variable_get(:@peers).keys.first
      AnilCoop.queue(type: "invite_request", request: "0123456789abcdef", target: peer, kind: "pvp", pvp: "singles-v1")
    else
      wait.call { !AnilCoop.instance_variable_get(:@incoming_invites).to_h.empty? }
      AnilCoop.queue(type: "invite_reply", request: "0123456789abcdef", accept: mode != "decline", pvp: "singles-v1")
    end
    if mode == "decline"
      150.times { AnilCoop.battle_tick; Graphics.update }
      raise "declined duel started" if AnilCoop.instance_variable_get(:@pvp_offer)
      report[:declined] = true
    else
      wait.call { AnilCoop.instance_variable_get(:@pvp_offer) }
      AnilCoop.pvp_poll
      report.merge!(AnilCoop.instance_variable_get(:@last_pvp_result))
    end
    if report[:complete]
      remote = AnilCoop.instance_variable_get(:@peers).keys.first
      previous = AnilCoop.instance_variable_get(:@peers).dig(remote, "position", "seq").to_i
      wait.call do
        AnilCoop.tick($scene)
        AnilCoop.instance_variable_get(:@peers).dig(remote, "position", "seq").to_i > previous
      end
      report[:position_after] = true
    end
    report[:connected] = AnilCoop.connected?
    report[:originals] = [$player, $PokemonGlobal, $bag, $stats].zip(original).all? { |a,b| a.equal?(b) } && $player.party.each_with_index.map { |p,i| AnilCoop.team_snapshot(p,i) } == party
    report[:save_intact] = Digest::SHA256.file(save).hexdigest == before
    report[:map_restored] = $scene.is_a?(Scene_Map) && !$game_temp.in_battle
    if report[:complete]
      raise "post-duel save failed" unless Game.save("Partida 2")
      saved = SaveData.get_data_from_file(SaveData.get_full_path("Partida 2"))
      SaveData.load_bootup_values(saved)
      Game.load(saved)
      report[:reload] = $player.party.each_with_index.map { |p, i| AnilCoop.team_snapshot(p, i) } == party
    end
  rescue StandardError => e
    report[:error] = "#{e.class}: #{e.message}"
    report[:trace] = e.backtrace.first(10)
  ensure
    File.write(File.join(AnilCoopDev::PROFILE,"qa-pvp-result.json"), JSON.generate(report)) unless report.empty?
    exit
  end
end
trace.enable
