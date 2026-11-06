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
    AnilCoop.trainer_send("trainer_start", event, solo: false) if state["host"] == AnilCoop.instance_variable_get(:@id)
    wait_until { AnilCoop.instance_variable_get(:@trainer_states)[key]&.dig("phase") == "locked" }
    state = AnilCoop.instance_variable_get(:@trainer_states)[key]
    visual = ENV["ANIL_COOP_QA_BOT"] == "visual"
    scene = visual ? nil : AnilCoopQA::EngineScene.new
    AnilCoop.qa_coop_battle(state, scene: scene, visual: visual)
    result = AnilCoop.instance_variable_get(:@last_qa_result) || { error: "no result" }
    10.times { Graphics.update; AnilCoop.tick($scene) }
    result[:connected_after] = AnilCoop.connected?
    result[:save_unchanged] = before == Digest::SHA256.file(path).hexdigest
    result[:scene_map] = $scene.is_a?(Scene_Map) && !$game_temp.in_battle
    result[:kind] = visual ? "rendered_engine_programmed_orders" : "engine_without_battle_rendering"
    result[:scenario] = scenario
    result[:pass] = result[:completed] && result[:decision] == (scenario == "loss" ? 2 : 1) &&
                    result[:connected_after] && result[:save_unchanged] && result[:scene_map]
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

  module Orders
    def pbCommandMenu(index, first_action)
      raise AnilCoop::BattleStopped, "QA exceeded 35 turns" if @turnCount >= 35
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
