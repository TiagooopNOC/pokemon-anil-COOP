# Two-owner trainer adapter with validated snapshots and local result receipts.
require "digest"

module AnilCoop
  class BattleStopped < StandardError; end

  def self.qa_2v2?
    ENV["ANIL_COOP_BATTLES"] == "1" || (ENV["ANIL_COOP_QA_2V2"] == "1" && ENV["ANIL_COOP_QA_TRAINER"] == "1")
  end

  def self.coop_battle_active?; !!@active_battle; end

  def self.check_battle_transport!
    return unless @active_battle && !@battle_completed && !@battle_cleanup
    raise BattleStopped, (@battle_failure || "connection lost") if @battle_failure || !connected?
  end

  def self.canonical_state(value)
    case value
    when NilClass, TrueClass, FalseClass, String, Integer, Float then value
    when Symbol then value.to_s
    when Array then value.map { |v| canonical_state(v) }
    when Hash
      value.keys.sort_by(&:to_s).map { |k| [canonical_state(k), canonical_state(value[k])] }
    else
      raise BattleStopped, "non-canonical state object: #{value.class}"
    end
  end

  def self.battle_receive(message)
    return unless @active_battle == message["battle"]
    if message["type"] == "battle_abort"
      @battle_failure = message["reason"]
      log("2v2 abort reason=#{message['reason']} diagnostic=#{JSON.generate(message['diagnostic'])}")
    elsif message["seq"] == @battle_seq
      @battle_reply = message
    end
  end

  def self.battle_wait_status(message)
    return unless @active_battle == message["battle"] && message["diagnostic"].is_a?(Hash)
    info = message["diagnostic"]
    return unless info["elapsed"].to_f >= 20
    now = System.uptime
    return if @battle_status_logged_at && now - @battle_status_logged_at < 30
    @battle_status_logged_at = now
    log("2v2 peer wait #{JSON.generate(info)} local=#{battle_debug_context}")
  end

  def self.battle_debug_context
    battle = @battle_context
    return "phase=#{@battle_phase || 'setup'}" unless battle
    battlers = battle.instance_variable_get(:@battlers) || []
    hp = battlers.map { |b| b ? b.hp : nil }
    "turn=#{battle.instance_variable_get(:@turnCount)} phase=#{@battle_phase || 'setup'} hp=#{hp.inspect}"
  end

  def self.battle_phase(phase)
    @battle_phase = phase
    log("2v2 phase #{battle_debug_context} seq=#{@battle_seq}")
  end

  def self.battle_barrier(stage, digest, command = nil, scene = nil)
    raise BattleStopped, "connection lost" unless connected? && @active_battle
    @battle_reply = nil
    queue(type: "battle_step", battle: @active_battle, seq: @battle_seq,
          stage: stage, digest: digest, command: command)
    @battle_phase = stage
    action = command.is_a?(Array) ? (command[0].is_a?(Array) ? command.map { |c| c[0] } : command[0]) : "none"
    log("2v2 submit seq=#{@battle_seq} stage=#{stage} action=#{action.inspect} #{battle_debug_context}")
    if scene && scene.respond_to?(:pbShowWindow)
      scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
      waiting_window = scene.sprites["messageWindow"]
      old_letterbyletter = waiting_window.letterbyletter
      waiting_window.letterbyletter = false
      waiting_window.text = "Esperando la orden del compañero..."
    end
    started = System.uptime
    next_report = started + 15
    loop do
      battle_tick
      raise BattleStopped, (@battle_failure || "connection lost") if @battle_failure || !connected?
      break if @battle_reply
      now = System.uptime
      if now >= next_report
        log("2v2 waiting seq=#{@battle_seq} stage=#{stage} elapsed=#{(now - started).round(1)} " \
            "#{battle_debug_context}")
        next_report = now + 15
      end
      Graphics.update
      Input.update
      scene.pbUpdate if scene
    end
    packet = @battle_reply
    raise BattleStopped, "invalid barrier reply" unless packet["stage"] == stage && packet["digest"] == digest
    @battle_seq += 1
    @battle_completed = true if stage == "result"
    log("2v2 barrier seq=#{packet['seq']} stage=#{stage} elapsed=#{(System.uptime - started).round(1)} " \
        "#{battle_debug_context}")
    packet
  ensure
    waiting_window.letterbyletter = old_letterbyletter if waiting_window
  end

  # Explicit, reproducible test Pokémon, never derived from either saved team.
  def self.test_pokemon(species, owner, pid, moves, ability)
    # Añil adds a sixth argument to suppress randomization for a supplied Pokémon.
    pkmn = Pokemon.new(species, 10, owner, false, false, false)
    pkmn.personalID = pid
    pkmn.nature = :HARDY
    pkmn.gender = 0
    pkmn.shiny = false
    pkmn.ability = ability
    pkmn.forced_ability = ability
    pkmn.item = nil
    pkmn.iv.each_key { |s| pkmn.iv[s] = 15; pkmn.ev[s] = 0 }
    pkmn.moves = moves.map { |m| Pokemon::Move.new(m) }
    pkmn.calc_stats
    pkmn.heal
    pkmn
  end

  def self.qa_coop_battle(state, scene: nil, visual: true)
    @last_qa_result = nil
    @last_battle_state = state
    outcome_variable = $game_temp.battle_rules["outcomeVar"] || 1
    can_lose = $game_temp.battle_rules["canLose"] || false
    # TrainerBattle.start_core fires this before constructing the battle; its
    # matching after_battle hook needs the party status/heart-gauge snapshots.
    EventHandlers.trigger(:on_start_battle) if @story_battle
    run_coop_battle(state, scene: scene, visual: visual)
    log("story post-battle reached story=#{@story_battle} completed=#{@last_qa_result && @last_qa_result[:completed]}") if @story_battle
    if state["enemy_team"] && @last_qa_result && @last_qa_result[:completed]
      BattleCreationHelperMethods.after_battle(@last_qa_result[:decision], can_lose) if @story_battle
      log("story after_battle returned") if @story_battle
      BattleCreationHelperMethods.set_outcome(@last_qa_result[:decision], outcome_variable, true)
    end
    $game_temp.clear_battle_rules
    state["prototype"] == "personal2v2-v1" && @last_qa_result &&
      @last_qa_result[:completed] && @last_qa_result[:decision] == 1 && @last_qa_result.dig(:application, :applied)
  end

  def self.run_coop_battle(state, scene: nil, visual: true)
    return false unless qa_2v2? && state["participants"].length == 2 &&
      (state["event"] == 9000 || state["prototype"] == "personal2v2-v1")
    @active_battle = state["battle"]
    @battle_seq = 0
    @battle_failure = nil
    @battle_completed = false
    @battle_cleanup = false
    @last_qa_result = nil
    # Trusted local copies protect personal objects even if a plugin accesses globals.
    originals = [$player, $PokemonGlobal, $bag, $stats]
    personal = state["prototype"] == "personal2v2-v1"
    result_plan = capture_result_plan(state, originals[0], originals[1]) if personal
    $player, $PokemonGlobal, $bag, $stats = Marshal.load(Marshal.dump(originals))
    # Legacy QA challenge profiles may predate the encounter ledger initialization.
    # Native scene hooks consult it even for trainer battles. Only repair the copy.
    $PokemonGlobal.challenge_encs ||= {} if $PokemonGlobal.respond_to?(:challenge_encs)
    names = state["participants"].map { |p| p["name"] }
    # Use the current, known valid trainer type for both test trainers.
    trainers = names.map { |n| NPCTrainer.new(n, $player.trainer_type) }
    trainers.each_with_index { |t, i| t.id = 100 + i }
    p1 = [test_pokemon(:BULBASAUR, trainers[0], 1001, [:TACKLE, :GROWL], :OVERGROW),
          test_pokemon(:SQUIRTLE, trainers[0], 1002, [:TACKLE, :TAILWHIP], :TORRENT),
          test_pokemon(:CHARMANDER, trainers[1], 2001, [:SCRATCH, :GROWL], :BLAZE),
          test_pokemon(:SQUIRTLE, trainers[1], 2002, [:TACKLE, :TAILWHIP], :TORRENT)]
    team_sizes = [2, 2]
    if personal
      local_owner = state["participants"].index { |p| p["id"] == @id }
      supplied = state.fetch("selected_teams").fetch(local_owner)
      current = supplied.map { |p| team_snapshot(originals[0].party.fetch(p["slot"]), p["slot"]) }
      raise BattleStopped, "El equipo cambió durante la espera" unless supplied == @selected_team && supplied == current
      team_sizes = state.fetch("selected_teams").map(&:length)
      trainers = state.fetch("selected_trainers").map do |data|
        raise BattleStopped, "Entrenador incompatible" unless GameData::TrainerType.exists?(data["trainer_type"])
        t = NPCTrainer.new(data["name"], data["trainer_type"].to_sym)
        t.id, t.language = data["id"], data["language"]
        t
      end
      p1 = state["selected_teams"].flatten.map { |data| team_pokemon(data) }
    end
    trainers[0].party = p1[0, team_sizes[0]]
    trainers[1].party = p1[team_sizes[0], team_sizes[1]]
    foe = NPCTrainer.new("Azul QA", :AZUL1)
    foe.id = 300
    enemy = test_pokemon(:CHARMANDER, foe, 3001, [:SCRATCH, :GROWL], :BLAZE)
    if personal
      enemy.level = 5
      enemy.calc_stats
      enemy.heal
    end
    # Clone trusted local data: HP, PP and effects of the duplicate are independent.
    p2 = [enemy, Marshal.load(Marshal.dump(enemy))]
    p2[1].personalID = 3002
    raise BattleStopped, "enemy clone aliases moves" if p2[0].moves[0].equal?(p2[1].moves[0])
    enemy_origins = [0, 0]
    if state["enemy_team"]
      data = state.fetch("enemy_trainer")
      foe = NPCTrainer.new(data["name"], data["trainer_type"].to_sym)
      foe.id, foe.language = data["id"], data["language"]
      foe.lose_text = data["lose_text"] if data.key?("lose_text")
      foe.win_text = data["win_text"] if data.key?("win_text")
      p2 = state["enemy_team"].map { |p| team_pokemon(p) }
      enemy_origins = (0...p2.length).to_a
      if p2.length == 1
        p2 << Marshal.load(Marshal.dump(p2[0]))
        enemy_origins << 0
      end
    end
    foe.party = p2
    scene ||= BattleCreationHelperMethods.create_battle_scene
    local_index = state["participants"].index { |p| p["id"] == @id } * 2
    battle = AnilCoopBattle.new(scene, p1, p2, trainers, [foe], local_index, state["seed"], team_sizes: team_sizes, personal: personal, enemy_origins: enemy_origins)
    @battle_context = battle
    if state["enemy_trainer"]
      inventory = state["enemy_trainer"].fetch("items", [])
      raise BattleStopped, "unsupported trainer item" unless inventory.is_a?(Array) &&
        inventory.length <= 4 && inventory.all? { |item| ["POTION", "SUPERPOTION"].include?(item) }
      battle.items = [inventory.map(&:to_sym)]
      battle.coop_allow_enemy_items! unless inventory.empty?
    end
    if personal
      supplied.each_with_index do |data, i|
        p1[battle.coop_owned_indices[i]].expshare = originals[0].party[data["slot"]].expshare
      end
    end
    battle_barrier("setup", battle.coop_digest)
    log("2v2 begin owned=#{local_index} temporary_teams=#{!personal}")
    battle_error = nil
    run = proc do
      begin
        battle.pbStartBattle
      rescue BattleStopped, StandardError => e
        # Let Essentials restore map sprites, music and in_battle before reporting.
        battle_error = e
      end
    end
    if visual
      pbBattleAnimation(pbGetTrainerBattleBGM([foe]), 3, [foe]) { pbSceneStandby { run.call } }
    else
      run.call
    end
    raise battle_error if battle_error
    @last_qa_result = { decision: battle.decision, completed: @battle_completed, rounds: battle.turnCount + 1 }
    @last_qa_result[:observed] = battle.qa_evidence if battle.respond_to?(:qa_evidence)
    @last_qa_result[:reward_preview] = battle.coop_reward_preview
    log("2v2 end decision=#{battle.decision} personal=#{personal} agreed=#{@battle_completed}")
    false
  rescue BattleStopped, StandardError => e
    @last_qa_result = { error: "#{e.class}: #{e.message}", completed: false }
    log("2v2 stopped #{e.class}: #{e.message}\n#{e.backtrace&.first(6)&.join("\n")}")
    pbMessage("Combate cooperativo detenido: #{e.message}. No se guardaron resultados.") unless @qa_automation
    false
  ensure
    if @active_battle && !@battle_completed
      queue(type: "battle_abort", battle: @active_battle) if connected?
      network
    end
    $player, $PokemonGlobal, $bag, $stats = originals if originals
    begin
      if result_plan && @battle_completed && @last_qa_result && @last_qa_result[:completed]
        @last_qa_result[:application] = apply_personal_result(result_plan, battle.pbParty(0), battle.decision, money: state["enemy_team"] ? battle.coop_money : 0)
        @last_personal_application = [result_plan, battle.pbParty(0), battle.decision, state["enemy_team"] ? battle.coop_money : 0]
      end
    rescue StandardError => e
      @last_qa_result[:error] = "result application: #{e.message}"
      @last_qa_result[:completed] = false
      log(@last_qa_result[:error])
    ensure
      @active_battle = @battle_failure = @battle_reply = nil
      @battle_context = @battle_phase = @battle_status_logged_at = nil
    end
  end
end

class AnilCoopBattle < Battle
  def coop_allow_enemy_items!; @coop_allow_enemy_items = true; end
  def coop_allow_enemy_items?; !!@coop_allow_enemy_items; end

  # Gary's opening line is attached to "foe" in Añil. In a double battle DBK
  # dispatches that trigger for both foes, even when the second is a copy.
  def pbDeluxeTriggers(idx_battler, idx_target, *triggers)
    index = idx_battler.respond_to?(:index) ? idx_battler.index : idx_battler
    opening = @midbattleScript == :azul_combate_inicial && @turnCount == 0 &&
      triggers == ["RoundStartCommand", 1] && index.is_a?(Integer) && index.odd?
    return if opening && @coop_gary_opening_shown
    result = super
    @coop_gary_opening_shown = true if opening
    result
  end

  def initialize(scene, allies, foes, trainers, opponents, local_index, seed, team_sizes: [2, 2], personal: false, enemy_origins: [0, 0])
    @coop_local = local_index
    @coop_team_sizes = team_sizes
    @coop_personal = personal
    super(scene, allies, foes, trainers, opponents)
    # Original Añil/LBDSKY map metadata, environment, weather and battle background.
    BattleCreationHelperMethods.prepare_battle(self)
    @party1starts = [0, team_sizes[0]]
    @party2starts = [0]
    setBattleMode("double")
    @internalBattle = @expGain = @moneyGain = @switchStyle = false
    @canLose = true
    @items = [[]]
    @ally_items = [[], []]
    @z_rng = ZCable::BattleRNG.new(seed)
    # Both QA foes originate from one trainer Pokémon. Never award its EXP twice.
    @coop_enemy_origins = enemy_origins
    @coop_defeated = {}
    @coop_rewards_applied = false
  end

  def coop_owned_indices
    start = @party1starts[@coop_local / 2]
    (start...start + @coop_team_sizes[@coop_local / 2]).to_a
  end

  def pbOwnedByPlayer?(index); index == @coop_local; end
  def pbCanMegaEvolve?(*); false; end
  RewardFoe = Struct.new(:pokemon, :level, :participants)
  attr_reader :coop_reward_preview

  # Record native participation now; local rewards must not alter a shared turn.
  def pbGainExp
    @battlers.compact.each do |b|
      next unless b.opposes? && b.fainted? && !b.participants.empty?
      origin = @coop_enemy_origins.fetch(b.pokemonIndex)
      record = @coop_defeated[origin] ||= RewardFoe.new(
        Marshal.load(Marshal.dump(b.pokemon)), b.level, [])
      record.participants |= b.participants
    end
  end

  def pbPlayer
    return (@coop_personal ? $player : @player[@coop_local / 2]) if @coop_reward_owner
    super
  end

  # QA preview only, on temporary teams, after the server has agreed on victory.
  # Persistence needs a durable battle receipt before this can touch saved teams.
  def coop_apply_reward_preview
    return if @coop_rewards_applied || @decision != 1 ||
              !AnilCoop.instance_variable_get(:@battle_completed)
    @coop_rewards_applied = true # Never retry a partially applied local reward.
    @coop_reward_owner = true
    owned = coop_owned_indices
    before = @party1.map { |p| [p.exp, p.level] }
    other = @party1.each_index.to_a - owned
    remote_before = Marshal.dump(other.map { |i| @party1[i] })
    no_exp = @coop_personal && defined?(NO_EXP_SWITCH) && $game_switches[NO_EXP_SWITCH]
    exp_all = @coop_personal && ($player.has_exp_all || $bag.has?(:EXPALL))
    exp_share = owned.select do |i|
      p = @party1[i]
      @coop_personal && !exp_all && p.able? && (p.expshare || p.hasItem?(:EXPSHARE) || @initialItems[0][i] == :EXPSHARE)
    end
    @coop_defeated.each_value do |foe|
      next if no_exp
      participants = foe.participants.select { |i| owned.include?(i) && @party1[i].able? }
      owned.each do |i|
        next unless @party1[i].able? && (participants.include?(i) || exp_share.include?(i) || exp_all)
        pbGainEVsOne(i, foe)
        pbGainExpOne(i, foe, participants.length, exp_share, exp_all)
      end
    end
    raise AnilCoop::BattleStopped, "reward changed remote team" unless
      remote_before == Marshal.dump(other.map { |i| @party1[i] })
    @coop_reward_preview = {
      owner: @coop_local / 2, enemy_origins: @coop_defeated.length,
      exp_delta: @party1.each_with_index.map { |p, i| p.exp - before[i][0] },
      levels_before: before.map(&:last), levels_after: @party1.map(&:level),
      remote_unchanged: true, persisted: false, money: 0
    }
    AnilCoop.log("2v2 reward preview #{JSON.generate(@coop_reward_preview)}")
  ensure
    @coop_reward_owner = false
  end
  def coop_money
    return 0 unless @decision == 1
    amount = @opponent[0].base_money * @party2.map(&:level).max
    used = @coop_defeated.values.flat_map(&:participants).uniq & coop_owned_indices
    amount *= 2 if used.any? { |i| [:AMULETCOIN, :LUCKINCENSE].include?(@initialItems[0][i]) }
    amount
  end

  def pbGainMoney; end
  def pbLoseMoney; end

  def pbItemMenu(_index, _first_action)
    pbDisplayPaused("Los objetos de bolsa aún no están habilitados en el combate cooperativo.")
    false
  end

  def pbRunMenu(_index)
    pbDisplayPaused("No puedes huir de un combate contra un entrenador.")
    false
  end

  # Hash only canonical engine state; local UI ownership must not enter the digest.
  def coop_digest
    parties = [@party1, @party2].map do |party|
      party.map do |p|
        [p.species, p.personalID, p.level, p.hp, p.totalhp, p.status, p.statusCount,
         p.form, p.ability_id, p.item_id, p.attack, p.defense, p.spatk, p.spdef, p.speed,
         p.moves.map { |m| [m.id, m.pp, m.total_pp] }]
      end
    end
    battlers = @battlers.map do |b|
      b && [b.index, b.pokemonIndex, b.hp, b.status, b.statusCount, b.stages,
            b.effects, b.ability_id, b.item_id, b.form,
            b.attack, b.defense, b.spatk, b.spdef, b.speed, b.participants.sort]
    end
    data = [parties, battlers, @field.effects, @field.weather, @field.terrain,
            @sides.map(&:effects), @turnCount, @decision,
            @field.weatherDuration, @field.terrainDuration,
            @priority.map { |entry| [entry[0].index, *entry[1..-1]] },
            @coop_defeated.sort.map { |origin, foe| [origin, foe.participants.sort] }, @items]
    encoded = JSON.generate(AnilCoop.canonical_state(data))
    File.write(File.join(AnilCoopDev::PROFILE, "qa-2v2-state.json"), encoded)
    Digest::SHA256.hexdigest(encoded)
  end

  def coop_order(index)
    return ["none", 0, -1] if @battlers[index].fainted?
    choice = @choices[index]
    case choice[0]
    when :UseMove
      target_data = choice[2].pbTarget(@battlers[index])
      automatic = target_data.num_targets == 0 || target_data.id == :RandomNearFoe
      ["move", choice[1], automatic ? -1 : choice[3]]
    when :SwitchOut then ["switch", choice[1], -1]
    when :UseItem
      raise AnilCoop::BattleStopped, "unsupported trainer item" unless
        [:POTION, :SUPERPOTION].include?(choice[1]) && choice[2].is_a?(Integer) && choice[3].nil?
      ["item", choice[1].to_s, choice[2]]
    when :None then ["none", 0, -1]
    else raise AnilCoop::BattleStopped, "unsupported action #{choice[0]}"
    end
  end

  def coop_apply(index, order)
    action, slot, target = order
    case action
    when "move"
      # Never accept a move index/target just because the transport accepted it.
      if slot >= 0
        raise AnilCoop::BattleStopped, "illegal move" unless pbCanChooseMove?(index, slot, false)
        move = @battlers[index].moves[slot]
      else
        raise AnilCoop::BattleStopped, "illegal struggle" if pbCanShowFightMenu?(index)
        move = @struggle
      end
      target_data = move.pbTarget(@battlers[index])
      automatic = target_data.num_targets == 0 || target_data.id == :RandomNearFoe
      valid_target = automatic ? target == -1 :
        (target == -1 || (target < @battlers.length && @battlers[target] &&
                          pbMoveCanTarget?(index, target, target_data)))
      unless valid_target
        AnilCoop.log("2v2 rejected target user=#{index} move=#{move.id} slot=#{slot} " \
                     "selected=#{target} rule=#{target_data.id} count=#{target_data.num_targets} " \
                     "side_sizes=#{@sideSizes.inspect} battler_hp=#{@battlers.map { |b| b&.hp }.inspect}")
        raise AnilCoop::BattleStopped, "illegal target"
      end
      @choices[index] = [:UseMove, slot, move, target]
    when "switch"
      pbClearChoice(index)
      raise AnilCoop::BattleStopped, "illegal switch" unless pbCanSwitch?(index, slot)
      pbRegisterSwitch(index, slot)
    when "item"
      raise AnilCoop::BattleStopped, "illegal trainer item" unless
        ["POTION", "SUPERPOTION"].include?(slot) && target.is_a?(Integer) &&
        target.between?(0, pbParty(index).length - 1)
      item = slot.to_sym
      if @choices[index][0] == :UseItem
        # The authoritative enemy AI already registered and consumed this item.
        raise AnilCoop::BattleStopped, "trainer item mismatch" unless
          @choices[index][1] == item && @choices[index][2] == target && @choices[index][3].nil?
      else
        raise AnilCoop::BattleStopped, "trainer item unavailable" unless pbGetOwnerItems(index).include?(item)
        pbRegisterItem(index, item, target)
      end
    when "none"
      raise AnilCoop::BattleStopped, "missing order" if pbCanShowCommands?(index)
    else
      raise AnilCoop::BattleStopped, "unknown order"
    end
  end

  def pbCommandPhaseLoop(is_player)
    if is_player
      AnilCoop.battle_phase("player_menu")
      digest = coop_digest  # before the local menu can register a switch
      super(true)
      packet = AnilCoop.battle_barrier("turn", digest, coop_order(@coop_local), @scene)
      packet["commands"].each_with_index { |order, i| coop_apply(i * 2, order) }
    else
      AnilCoop.battle_phase("enemy_ai")
      digest = coop_digest
      commands = nil
      if @coop_local == 0
        [1, 3].each do |i|
          @battleAI.pbDefaultChooseEnemyCommand(i) if pbCanShowCommands?(i)
        end
        commands = [coop_order(1), coop_order(3)]
      end
      packet = AnilCoop.battle_barrier("enemy", digest, commands, @scene)
      packet["commands"][0].each_with_index { |order, i| coop_apply(i * 2 + 1, order) }
      @z_rng = ZCable::BattleRNG.new(packet["seed"])
    end
  end

  def pbSwitchInBetween(index, check_lax = false, can_cancel = false)
    AnilCoop.battle_phase("replacement_#{index}")
    if index.odd?
      selected = super
      AnilCoop.log("2v2 enemy replacement index=#{index} slot=#{selected}")
      return selected
    end
    # The fixture has no pivot moves: replacement is mandatory after fainting.
    digest = coop_digest
    selected = index == @coop_local ? pbPartyScreen(index, check_lax, false) : -1
    packet = AnilCoop.battle_barrier("switch", digest, [index, selected], @scene)
    selected = packet["commands"][index / 2][1]
    raise AnilCoop::BattleStopped, "illegal replacement" unless selected >= 0 && pbCanSwitchIn?(index, selected)
    AnilCoop.log("2v2 player replacement index=#{index} slot=#{selected}")
    selected
  end

  def pbReplace(index, party_index, baton_pass = false)
    AnilCoop.battle_phase("sendout_#{index}")
    result = super
    AnilCoop.log("2v2 sent out index=#{index} slot=#{party_index} turn=#{@turnCount}")
    result
  end

  def pbEndOfRoundPhase
    AnilCoop.battle_phase("end_of_round")
    super
    AnilCoop.battle_barrier("state", coop_digest, nil, @scene)
  end

  def pbEndOfBattle
    AnilCoop.battle_phase("end_of_battle")
    AnilCoop.battle_barrier("result", coop_digest, nil, @scene)
    coop_apply_reward_preview
    super
  end

  def pbStartBattle
    super
  rescue AnilCoop::BattleStopped, StandardError => error
    AnilCoop.instance_variable_set(:@battle_cleanup, true)
    @decision = 0
    AnilCoop.close_battle_menus if AnilCoop.respond_to?(:close_battle_menus)
    begin
      @scene.pbEndBattle(0)
    rescue StandardError => cleanup_error
      AnilCoop.log("battle cleanup: #{cleanup_error.class}: #{cleanup_error.message}")
    end
    raise error
  end
end

# Essentials' enemy item AI is gated by internalBattle. Keep the co-op battle
# external for Pokédex/reward safety, and expose that flag only while the AI
# decides whether to use its own trainer medicine.
module AnilCoopEnemyItemAI
  def choose_item_to_use
    battle = @battle
    return super unless battle.is_a?(AnilCoopBattle) && battle.coop_allow_enemy_items?
    previous = battle.internalBattle
    begin
      battle.internalBattle = true
      super
    ensure
      battle.internalBattle = previous
    end
  end
end
Battle::AI.prepend(AnilCoopEnemyItemAI)

class Battle::Scene
  # Native level-up stat windows otherwise wait for input without a scene update.
  # Keep the session alive while a human reads them; ordinary battles stay native.
  def pbTopRightWindow(text, scene = nil)
    super(text, AnilCoop.coop_battle_active? ? self : scene)
  end
end

class << Game
  alias_method :anil_coop_battle_save, :save unless method_defined?(:anil_coop_battle_save)
  def save(*args)
    return false if AnilCoop.coop_battle_active? || ENV["ANIL_COOP_QA_BOT"]
    anil_coop_battle_save(*args)
  end
end

class << PBDebug
  alias_method :anil_coop_logonerr, :logonerr unless method_defined?(:anil_coop_logonerr)
  def logonerr(&block)
    # Essentials normally reports and swallows errors here. A network turn must
    # abort both replicas instead of continuing after a failed validation/action.
    return yield if AnilCoop.coop_battle_active?
    anil_coop_logonerr(&block)
  end
end
