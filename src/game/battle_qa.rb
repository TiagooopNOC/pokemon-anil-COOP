# Opt-in integration driver: native Essentials engine, programmed commands, no OS input.
# Never enabled by normal launchers. Read-only isolated save loading; results discarded.
module AnilCoopQA
  def self.scenario; ENV["ANIL_COOP_QA_SCENARIO"] || "basic"; end

  def self.wait_until(seconds = 35)
    deadline = System.uptime + seconds
    loop do
      Graphics.update
      AnilCoop.tick($scene)
      return if yield
      raise "QA deadline exceeded" if System.uptime > deadline
    end
  end

  def self.run
    AnilCoop.instance_variable_set(:@qa_automation, true)
    path = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before = Digest::SHA256.file(path).hexdigest
    save_data = SaveData.get_data_from_file(path) # no conversion/write-back
    SaveData.load_bootup_values(save_data)
    Game.load(save_data)
    if ["personal-reserves", "personal-share"].include?(scenario)
      # Explicit synthetic six-slot QA party, only in RAM; never a fallback for users.
      source = $player.party.fetch(0)
      $player.party = Array.new(6) do |i|
        p = Marshal.load(Marshal.dump(source))
        p.personalID = (source.personalID + 10000 + i) % (2**32)
        p.calc_stats
        p.heal
        p.hp = 1 if scenario == "personal-reserves" && [0, 2].include?(i)
        p
      end
      if scenario == "personal-share"
        $player.has_exp_all = ENV["ANIL_COOP_NAME"] == "client03"
        $player.party.each { |p| p.expshare = false }
        $player.party[4].expshare = true unless $player.has_exp_all
      end
      AnilCoop.log("QA synthetic six-slot party; selecting [2,0,4]")
    end
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0) # Mirror Scene_Map.main's initialization in this driver.
    wait_until do
      peers = AnilCoop.instance_variable_get(:@peers)
      AnilCoop.connected? && peers.length == 1 && peers.values.all? { |p| p["position"].is_a?(Hash) }
    end
    AnilCoop.qa_trainer
    event = $game_map.events.fetch(9000)
    before_money = $player.money
    before_exp = $player.party.map(&:exp)
    visual = ENV["ANIL_COOP_QA_BOT"] == "visual"
    if scenario == "personal-event"
      # Fix only the QA encounter initiator, so this victory scenario uses the
      # Normal profile's native Azul team rather than a random host race.
      if ENV["ANIL_COOP_NAME"] == "client04"
        wait_until { AnilCoop.instance_variable_get(:@trainer_states)[[event.map_id, event.id]]&.dig("phase") == "pending" }
      end
      my_id = AnilCoop.instance_variable_get(:@id)
      remote_id = AnilCoop.instance_variable_get(:@peers).keys.first
      remote_before = AnilCoop.instance_variable_get(:@peers)[remote_id]["position"].dup
      interpreter = pbMapInterpreter
      interpreter.setup(event.list, event.id)
      while interpreter.running?
        Graphics.update
        AnilCoop.tick($scene)
        interpreter.update
      end
      state = AnilCoop.instance_variable_get(:@last_battle_state)
      raise "NPC event did not start a battle" unless state
    else
    lobby_extra = { forced: false, prototype: AnilCoop.battle_prototype }
    if scenario == "personal-npc"
      lobby_extra[:encounter_key] = AnilCoop.trainer_identity(event, [:AZUL1, "Azul", 1])
    end
    AnilCoop.trainer_send("trainer_wait", event, lobby_extra)
    key = [event.map_id, event.id]
    wait_until do
      state = AnilCoop.instance_variable_get(:@trainer_states)[key]
      state && state["participants"].any? { |p| p["id"] == AnilCoop.instance_variable_get(:@id) }
    end
    if AnilCoop.personal_team?
      AnilCoop.trainer_send("trainer_team", event, team: AnilCoop.select_team(["personal-reserves", "personal-share"].include?(scenario) ? [2, 0, 4] : [0]), trainer: AnilCoop.trainer_snapshot)
    end
    AnilCoop.trainer_send("trainer_ready", event, ready: true)
    wait_until do
      state = AnilCoop.instance_variable_get(:@trainer_states)[key]
      state && state["participants"].length == 2 && state["participants"].all? { |p| p["ready"] }
    end
    state = AnilCoop.instance_variable_get(:@trainer_states)[key]
    my_id = AnilCoop.instance_variable_get(:@id)
    remote_id = state["participants"].find { |p| p["id"] != my_id }["id"]
    remote_before = AnilCoop.instance_variable_get(:@peers)[remote_id]["position"].dup
    if state["host"] == AnilCoop.instance_variable_get(:@id)
      AnilCoop.send_trainer_foe(event, [:AZUL1, "Azul", 1]) if scenario == "personal-npc"
      AnilCoop.trainer_send("trainer_start", event, solo: false)
    end
    wait_until { AnilCoop.instance_variable_get(:@trainer_states)[key]&.dig("phase") == "locked" }
    state = AnilCoop.instance_variable_get(:@trainer_states)[key]
    visual = ENV["ANIL_COOP_QA_BOT"] == "visual"
    scene = visual ? AnilCoopQA::VisualScene.new : AnilCoopQA::EngineScene.new
    AnilCoop.qa_coop_battle(state, scene: scene, visual: visual)
    end
    personal_exp = $player.party.each_with_index.map { |p, i| p.exp - before_exp[i] }
    result = AnilCoop.instance_variable_get(:@last_qa_result) || { error: "no result" }
    10.times { Graphics.update; AnilCoop.tick($scene) }
    result[:event_victory] = $game_self_switches[[$game_map.map_id, 9000, "A"]] if scenario == "personal-event"
    result[:personal_money_delta] = $player.money - before_money
    result[:personal_exp_delta] = personal_exp if AnilCoop.personal_team?
    result[:connected_after] = AnilCoop.connected?
    result[:save_unchanged] = before == Digest::SHA256.file(path).hexdigest
    result[:scene_map] = $scene.is_a?(Scene_Map) && !$game_temp.in_battle
    if result[:completed] && AnilCoop.personal_team?
      plan, party, decision, money = AnilCoop.instance_variable_get(:@last_personal_application)
      before_replay = Marshal.dump($player.party)
      replay = AnilCoop.apply_personal_result(plan, party, decision, money: money || 0)
      result[:personal_replay_safe] = replay == false && before_replay == Marshal.dump($player.party)
      # New QA-only file; never overwrite Partida 1 or another existing save.
      saved = File.join(AnilCoopDev::PROFILE, "qa-personal-#{state['battle']}.rxdata")
      raise "QA save already exists" if File.exist?(saved)
      SaveData.save_to_file(saved)
      expected_party = Marshal.dump($player.party)
      $scene.disposeSpritesets
      data = SaveData.get_data_from_file(saved)
      SaveData.load_bootup_values(data)
      Game.load(data)
      $scene.createSpritesets
      Graphics.transition(0)
      expected_objects = Marshal.load(expected_party)
      diffs = expected_objects.each_with_index.flat_map do |old, i|
        now = $player.party[i]
        (old.instance_variables | now.instance_variables).filter_map do |key|
          a, b = old.instance_variable_get(key), now.instance_variable_get(key)
          [i, key, a.inspect, b.inspect] unless Marshal.dump(a) == Marshal.dump(b)
        end
      end
      result[:reload_differences] = diffs
      # LBDSKY refreshes its party-time measurement clock while rebuilding the map.
      # Every other Pokemon instance variable still has to survive identically.
      result[:personal_save_reload] = diffs.all? { |row| row[1] == :@last_update_time } &&
        $PokemonGlobal.anil_coop_receipts.key?(state["battle"])
      result[:trainer_completed] = AnilCoop.trainer_completed?(state["encounter_key"]) if state["encounter_key"]
      result[:reload_replay_safe] = AnilCoop.apply_personal_result(plan, party, decision, money: money || 0) == false
    end
    if result[:completed]
      delta = state["host"] == my_id ? 1 : 2
      $game_player.moveto($game_player.x, $game_player.y + delta)
      wait_until(12) do
        peer = AnilCoop.instance_variable_get(:@peers)[remote_id]
        peer && peer.dig("position", "y") == remote_before["y"] + (3 - delta) &&
          AnilCoop.instance_variable_get(:@sprites).key?(remote_id)
      end
      result[:peer_visible_after] = true
      deadline = System.uptime + 2
      while System.uptime < deadline
        $scene.miniupdate
        Graphics.update
      end
      if visual
        bitmap = Graphics.snap_to_bitmap
        bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-2v2-map.png"))
        colors = []
        8.times do |x|
          8.times do |y|
            pixel = bitmap.get_pixel(x * bitmap.width / 8, y * bitmap.height / 8)
            colors << [pixel.red, pixel.green, pixel.blue]
          end
        end
        result[:map_rendered] = colors.uniq.length >= 6
        bitmap.dispose
      end
    end
    result[:kind] = visual ? "rendered_engine_programmed_orders" : "engine_without_battle_rendering"
    result[:scenario] = scenario
    result[:menu_checks] = @menu_checks if @menu_checks
    result[:pass] = result[:completed] && result[:decision] == (scenario == "loss" ? 2 : 1) &&
                    result[:connected_after] && result[:save_unchanged] && result[:scene_map] && result[:peer_visible_after]
    result[:pass] &&= result[:map_rendered] if visual
    if AnilCoop.personal_team?
      result[:pass] &&= result.dig(:application, :applied) && result.dig(:application, :unselected_unchanged) &&
        result[:personal_replay_safe] && result[:personal_save_reload] && result[:reload_replay_safe]
    end
    if ["disconnect", "menu-disconnect"].include?(scenario)
      result[:pass] = !result[:completed] && result[:error].to_s.match?(/connection lost|battle_disconnect/) &&
                      result[:save_unchanged] && result[:scene_map]
      if scenario == "menu-disconnect"
        result[:pass] &&= result.dig(:menu_checks, :connected_after_35_seconds) &&
          Array(AnilCoop.instance_variable_get(:@battle_menus)).empty?
      end
    elsif scenario == "desync"
      result[:pass] = !result[:completed] && result[:error].to_s.include?("battle_desync") &&
                      result[:save_unchanged] && result[:scene_map]
    elsif scenario == "status"
      result[:pass] &&= result.dig(:observed, :poison) && result.dig(:observed, :item_consumed)
    elsif scenario == "automatic-target"
      result[:pass] &&= result.dig(:observed, :automatic_target_wire)
    elsif ["personal-npc", "personal-event"].include?(scenario)
      result[:pass] &&= result[:trainer_completed] && result[:personal_money_delta] > 0
      result[:pass] &&= result[:event_victory] if scenario == "personal-event"
    elsif scenario == "personal-share"
      delta = result[:personal_exp_delta]
      result[:pass] &&= [1, 3, 5].all? { |i| delta[i] == 0 } && delta[2] > 0 && delta[4] > 0 &&
        (ENV["ANIL_COOP_NAME"] == "client03" ? delta[0] > 0 : delta[0] == 0)
    elsif scenario == "personal-reserves"
      result[:pass] &&= result.dig(:observed, :voluntary_switch) && result.dig(:observed, :forced_replacement)
    elsif scenario == "switch"
      result[:pass] &&= result.dig(:observed, :voluntary_switch)
    elsif scenario == "loss"
      result[:pass] &&= result.dig(:observed, :forced_replacement)
    elsif scenario == "rewards"
      reward = result[:reward_preview] || {}
      result[:pass] &&= reward[:remote_unchanged] && reward[:enemy_origins] == 1 &&
        reward[:exp_delta]&.any? { |v| v > 0 } &&
        reward[:levels_after]&.zip(reward[:levels_before])&.any? { |a, b| a > b } &&
        result.dig(:observed, :reward_replay_safe)
    end
    File.write(File.join(AnilCoopDev::PROFILE, "qa-2v2-result.json"), JSON.pretty_generate(result))
    AnilCoop.log("QA RESULT #{JSON.generate(result)}")
  rescue StandardError => e
    File.write(File.join(AnilCoopDev::PROFILE, "qa-2v2-result.json"),
               JSON.generate(pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(8)))
    AnilCoop.log("QA ERROR #{e.class}: #{e.message}")
  ensure
    AnilCoop.disconnect
    exit
  end

  # Essentials' own nonvisual scene, with only rendering-only DBK callbacks added.
  class EngineScene < Battle::DebugSceneNoVisuals
    attr_reader :sprites
    SpriteState = Struct.new(:vanishMode)
    def initialize
      super
      @sprites = {}
      4.times { |i| @sprites["pokemon_#{i}"] = SpriteState.new(0) }
    end
    def pbAnimateSubstitute(*); end
    def pbUpdateSubstituteSprite(*); end
    def pbAnimateTrainerIntros; end
    def pbDeleteTrickRoomBackground; end
    def pbRevertBattlerStart(*); end
    def pbRevertBattlerEnd(*); end
    def pbCommonAnimationExists(*); false; end
    def pbSetFieldBackground; end
    def pbUpdateHazardSprites; end
    def pbForceEndSpeech; end
    def pbItemUseAnimation(*); end
    def pbRefreshEverything; end
  end

  class VisualScene < Battle::Scene
    # Timed confirmation only in the QA driver, using the native stat window.
    def pbTopRightWindow(text, _scene = nil)
      window = Window_AdvancedTextPokemon.new(text)
      window.width = 198
      window.x = Graphics.width - window.width
      window.z = 99999
      deadline = System.uptime + 1
      loop do
        pbUpdate(window)
        break if System.uptime >= deadline
      end
      bitmap = Graphics.snap_to_bitmap
      bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-2v2-levelup.png"))
    ensure
      bitmap&.dispose
      window&.dispose
    end

    def pbDisplayPausedMessage(message)
      pbDisplayMessage(message)
    end

    def pbDisplayMessage(message, brief = false, &block)
      AnilCoop.log("QA message #{message}")
      super(message.delete("\x01"), brief, &block)
    end

    def pbUpdate(window = nil)
      super
      # The bot advances text pages through Essentials' API, never OS key input.
      window.resume if window && window.respond_to?(:pausing?) && window.pausing?
      @qa_last_capture ||= System.uptime
      if System.uptime - @qa_last_capture >= 15
        @qa_last_capture = System.uptime
        bitmap = Graphics.snap_to_bitmap
        bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-2v2-live.png"))
        bitmap.dispose
      end
    end
  end

  module Orders
    def qa_evidence; @qa_evidence ||= {}; end

    def coop_apply_reward_preview
      super
      if AnilCoopQA.scenario == "rewards"
        before = Marshal.dump(@party1)
        super # Deliberate replay: the reward must be applied at most once.
        qa_evidence[:reward_replay_safe] = before == Marshal.dump(@party1)
      end
    end

    def qa_observe
      qa_evidence[:poison] = true if @battlers.compact.any? { |b| b.status == :POISON }
      qa_evidence[:stat_change] = true if @battlers.compact.any? { |b| b.stages.values.any? { |v| v != 0 } }
      if AnilCoopQA.scenario == "status"
        qa_evidence[:item_consumed] = true if (@party1 + @party2).any? { |p| p.item_id.nil? }
      end
    end

    def pbAttackPhase
      super
      qa_observe
    end

    def coop_order(index)
      order = super
      if AnilCoopQA.scenario == "automatic-target" && @turnCount == 0 && index == 0
        qa_evidence[:automatic_target_wire] = order == ["move", 1, -1]
      end
      order
    end

    def coop_apply(index, order)
      if AnilCoopQA.scenario == "automatic-target" && @turnCount == 0 && index == 0
        qa_evidence[:automatic_target_wire] = order == ["move", 1, -1]
      end
      super
    end

    def pbEndOfRoundPhase
      if @turnCount == 0 && @coop_local == 2 && AnilCoopQA.scenario == "desync"
        @battlers[0].hp -= 1 # Negative test: validation must reject this corruption.
      end
      super
      qa_observe
    end

    def pbSwitchInBetween(index, *args)
      result = super
      qa_evidence[:forced_replacement] = true if index.even? && @battlers[index].fainted? && result >= 0
      result
    end

    def pbCommandMenu(index, first_action)
      raise AnilCoop::BattleStopped, "QA exceeded 35 turns" if @turnCount >= 35
      if @turnCount == 0 && AnilCoopQA.scenario == "menu-disconnect"
        party = PokemonParty_Scene.new
        displayed = pbPlayerDisplayParty(index)
        party.pbStartScene(displayed, "Prueba de conexión en reservas")
        summary = PokemonSummary_Scene.new
        summary.pbStartScene(displayed, 0, true)
        started = System.uptime
        loop do
          Graphics.update
          party.update
          summary.pbUpdate
          elapsed = System.uptime - started
          if elapsed >= 35
            AnilCoopQA.instance_variable_set(:@menu_checks, { connected_after_35_seconds: AnilCoop.connected? })
            if @coop_local == 2 && elapsed >= 38
              bitmap = Graphics.snap_to_bitmap
              bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-2v2-summary.png"))
              bitmap.dispose
              AnilCoop.disconnect
              AnilCoop.check_battle_transport!
            end
          end
          raise "QA menu disconnect deadline" if elapsed > 55
        end
      end
      if @turnCount == 1 && @coop_local == 2 && AnilCoopQA.scenario == "disconnect"
        AnilCoop.disconnect
        raise AnilCoop::BattleStopped, "connection lost (injected by QA)"
      end
      if ENV["ANIL_COOP_QA_BOT"] == "visual" && @turnCount == 0
        bitmap = Graphics.snap_to_bitmap
        bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-2v2-battle.png"))
        bitmap.dispose
      end
      return 2 if ["switch", "personal-reserves"].include?(AnilCoopQA.scenario) && @turnCount == 0
      0
    end

    def pbFightMenu(index)
      slot = (@turnCount == 0 && ["basic", "automatic-target"].include?(AnilCoopQA.scenario) && index == 0) ? 1 : 0
      slot = 2 if AnilCoopQA.scenario == "status" && index == 0 && @turnCount < 2
      slot = (0...@battlers[index].moves.length).find { |i| pbCanChooseMove?(index, i, false) } unless pbCanChooseMove?(index, slot, false)
      return pbAutoChooseMove(index) unless slot
      raise "QA move rejected" unless pbRegisterMove(index, slot)
      move = @battlers[index].moves[slot]
      targets = @battlers.compact.reject(&:fainted?).select do |b|
        b.opposes?(index) && pbMoveCanTarget?(index, b.index, move.pbTarget(@battlers[index]))
      end
      target = targets.empty? ? -1 : targets[@turnCount % targets.length].index
      # Essentials' human target window returns the user's index for self/side
      # moves, even though pbMoveCanTarget? intentionally rejects that cursor.
      target = index if AnilCoopQA.scenario == "automatic-target" && @turnCount == 0 && index == 0
      pbRegisterTarget(index, target)
      AnilCoop.log("QA order turn=#{@turnCount} owner=#{index} move=#{move.id} target=#{target}")
      true
    end

    def pbPartyScreen(index, check_lax = false, can_cancel = false, register = false)
      selected = (0...pbParty(index).length).find { |i| pbCanSwitchIn?(index, i) }
      raise "QA no replacement" unless selected
      pbRegisterSwitch(index, selected) if register
      qa_evidence[:voluntary_switch] = true if register && !@battlers[index].fainted?
      AnilCoop.log("QA switch owner=#{index} party_index=#{selected}")
      selected
    end

    def pbDisplayPaused(message, &block)
      # Programmed integration run: let the existing timed message renderer advance.
      @scene.pbDisplayMessage(message, &block)
    end
  end

  module EventDriver
    def trainer_choice(key, text, commands, &block)
      return super unless AnilCoopQA.scenario == "personal-event"
      super do
        state = instance_variable_get(:@trainer_states)[key]
        me = state["participants"].find { |p| p["id"] == instance_variable_get(:@id) }
        if !@qa_lobby_captured && state["participants"].length == 2 && state["participants"].all? { |p| p["team_count"] > 0 }
          bitmap = Graphics.snap_to_bitmap
          bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-2v2-lobby.png"))
          bitmap.dispose
          @qa_lobby_captured = true
        end
        if !me["ready"]
          0
        elsif state["host"] == me["id"] && state["participants"].length == 2 && state["participants"].all? { |p| p["ready"] }
          2
        end
      end
    end

    def choose_team(event)
      return super unless AnilCoopQA.scenario == "personal-event"
      trainer_send("trainer_team", event, team: select_team([0]), trainer: trainer_snapshot)
      true
    end

    def qa_coop_battle(state, scene: nil, visual: true)
      if AnilCoopQA.scenario == "personal-event"
        visual = ENV["ANIL_COOP_QA_BOT"] == "visual"
        scene = visual ? AnilCoopQA::VisualScene.new : AnilCoopQA::EngineScene.new
      end
      super(state, scene: scene, visual: visual)
    end
  end

  module Fixtures
    def test_pokemon(species, owner, pid, moves, ability)
      pkmn = super
      if AnilCoopQA.scenario == "automatic-target" && pid == 1001
        pkmn.moves = [:TACKLE, :SPLASH].map { |id| Pokemon::Move.new(id) }
      elsif AnilCoopQA.scenario == "personal-share" && pid == 3001
        pkmn.moves = [Pokemon::Move.new(:SPLASH)]
      elsif AnilCoopQA.scenario == "loss" && pid == 3001
        pkmn.level = 40
        pkmn.calc_stats
        pkmn.heal
      elsif AnilCoopQA.scenario == "status"
        pkmn.moves << Pokemon::Move.new(:POISONPOWDER) if pid == 1001
        pkmn.item = :ORANBERRY
      elsif AnilCoopQA.scenario == "rewards"
        if pid < 3000
          pkmn.exp = pkmn.growth_rate.minimum_exp_for_level(11) - 1
        else
          # Isolate reward UI from KO randomness: both owners must remain eligible.
          pkmn.moves = [Pokemon::Move.new(:SPLASH)]
        end
      end
      pkmn
    end
  end
end

AnilCoopBattle.prepend(AnilCoopQA::Orders)
AnilCoop.singleton_class.prepend(AnilCoopQA::Fixtures)
AnilCoop.singleton_class.prepend(AnilCoopQA::EventDriver)
$anil_coop_qa_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_qa_trace.disable
  AnilCoopQA.run
end
$anil_coop_qa_trace.enable
