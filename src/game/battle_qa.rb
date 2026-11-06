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
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0) # Mirror Scene_Map.main's initialization in this driver.
    wait_until { AnilCoop.connected? && AnilCoop.instance_variable_get(:@peers).length == 1 }
    AnilCoop.qa_trainer
    event = $game_map.events.fetch(9000)
    AnilCoop.trainer_send("trainer_wait", event, forced: false, prototype: "qa2v2-v1")
    key = [event.map_id, event.id]
    wait_until do
      state = AnilCoop.instance_variable_get(:@trainer_states)[key]
      state && state["participants"].any? { |p| p["id"] == AnilCoop.instance_variable_get(:@id) }
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
    AnilCoop.trainer_send("trainer_start", event, solo: false) if state["host"] == AnilCoop.instance_variable_get(:@id)
    wait_until { AnilCoop.instance_variable_get(:@trainer_states)[key]&.dig("phase") == "locked" }
    state = AnilCoop.instance_variable_get(:@trainer_states)[key]
    visual = ENV["ANIL_COOP_QA_BOT"] == "visual"
    scene = visual ? AnilCoopQA::VisualScene.new : AnilCoopQA::EngineScene.new
    AnilCoop.qa_coop_battle(state, scene: scene, visual: visual)
    result = AnilCoop.instance_variable_get(:@last_qa_result) || { error: "no result" }
    10.times { Graphics.update; AnilCoop.tick($scene) }
    result[:connected_after] = AnilCoop.connected?
    result[:save_unchanged] = before == Digest::SHA256.file(path).hexdigest
    result[:scene_map] = $scene.is_a?(Scene_Map) && !$game_temp.in_battle
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
    result[:pass] = result[:completed] && result[:decision] == (scenario == "loss" ? 2 : 1) &&
                    result[:connected_after] && result[:save_unchanged] && result[:scene_map] && result[:peer_visible_after]
    result[:pass] &&= result[:map_rendered] if visual
    if scenario == "disconnect"
      result[:pass] = !result[:completed] && result[:error].to_s.match?(/connection lost|battle_disconnect/) &&
                      result[:save_unchanged] && result[:scene_map]
    elsif scenario == "desync"
      result[:pass] = !result[:completed] && result[:error].to_s.include?("battle_desync") &&
                      result[:save_unchanged] && result[:scene_map]
    elsif scenario == "status"
      result[:pass] &&= result.dig(:observed, :poison) && result.dig(:observed, :item_consumed)
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
      if @turnCount == 1 && @coop_local == 2 && AnilCoopQA.scenario == "disconnect"
        AnilCoop.disconnect
        raise AnilCoop::BattleStopped, "connection lost (injected by QA)"
      end
      if ENV["ANIL_COOP_QA_BOT"] == "visual" && @turnCount == 0
        bitmap = Graphics.snap_to_bitmap
        bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-2v2-battle.png"))
        bitmap.dispose
      end
      return 2 if AnilCoopQA.scenario == "switch" && @turnCount == 0
      0
    end

    def pbFightMenu(index)
      slot = (@turnCount == 0 && AnilCoopQA.scenario == "basic") ? 1 : 0
      slot = 2 if AnilCoopQA.scenario == "status" && index == 0 && @turnCount < 2
      slot = (0...@battlers[index].moves.length).find { |i| pbCanChooseMove?(index, i, false) } unless pbCanChooseMove?(index, slot, false)
      return pbAutoChooseMove(index) unless slot
      raise "QA move rejected" unless pbRegisterMove(index, slot)
      move = @battlers[index].moves[slot]
      targets = @battlers.compact.reject(&:fainted?).select do |b|
        b.opposes?(index) && pbMoveCanTarget?(index, b.index, move.pbTarget(@battlers[index]))
      end
      target = targets.empty? ? -1 : targets[@turnCount % targets.length].index
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

  module Fixtures
    def test_pokemon(species, owner, pid, moves, ability)
      pkmn = super
      if AnilCoopQA.scenario == "loss" && pid == 3001
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
$anil_coop_qa_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_qa_trace.disable
  AnilCoopQA.run
end
$anil_coop_qa_trace.enable
