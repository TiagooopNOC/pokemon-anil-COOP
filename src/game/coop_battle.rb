# Experimental QA fixture only. No network Marshal, persistence or story hooks.
require "digest"

module AnilCoop
  class BattleStopped < StandardError; end

  def self.qa_2v2?
    ENV["ANIL_COOP_QA_2V2"] == "1" && ENV["ANIL_COOP_QA_TRAINER"] == "1"
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
    elsif message["seq"] == @battle_seq
      @battle_reply = message
    end
  end

  def self.battle_barrier(stage, digest, command = nil, scene = nil)
    raise BattleStopped, "connection lost" unless connected? && @active_battle
    @battle_reply = nil
    queue(type: "battle_step", battle: @active_battle, seq: @battle_seq,
          stage: stage, digest: digest, command: command)
    log("2v2 submit seq=#{@battle_seq} stage=#{stage} digest=#{digest}")
    if scene && scene.respond_to?(:pbShowWindow)
      scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
      waiting_window = scene.sprites["messageWindow"]
      old_letterbyletter = waiting_window.letterbyletter
      waiting_window.letterbyletter = false
      waiting_window.text = "Esperando la orden del compañero..."
    end
    deadline = System.uptime + 120
    loop do
      battle_tick
      raise BattleStopped, (@battle_failure || "connection lost") if @battle_failure || !connected?
      break if @battle_reply
      raise BattleStopped, "timeout waiting for partner" if System.uptime > deadline
      Graphics.update
      Input.update
      scene.pbUpdate if scene
    end
    packet = @battle_reply
    raise BattleStopped, "invalid barrier reply" unless packet["stage"] == stage && packet["digest"] == digest
    @battle_seq += 1
    @battle_completed = true if stage == "result"
    log("2v2 barrier seq=#{packet['seq']} stage=#{stage} digest=#{digest}")
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
    return false unless qa_2v2? && state["event"] == 9000 && state["participants"].length == 2
    @active_battle = state["battle"]
    @battle_seq = 0
    @battle_failure = nil
    @battle_completed = false
    @battle_cleanup = false
    @last_qa_result = nil
    # Trusted local copies protect personal objects even if a plugin accesses globals.
    originals = [$player, $PokemonGlobal, $bag, $stats]
    $player, $PokemonGlobal, $bag, $stats = Marshal.load(Marshal.dump(originals))
    names = state["participants"].map { |p| p["name"] }
    # Use the current, known valid trainer type for both test trainers.
    trainers = names.map { |n| NPCTrainer.new(n, $player.trainer_type) }
    trainers.each_with_index { |t, i| t.id = 100 + i }
    p1 = [test_pokemon(:BULBASAUR, trainers[0], 1001, [:TACKLE, :GROWL], :OVERGROW),
          test_pokemon(:SQUIRTLE, trainers[0], 1002, [:TACKLE, :TAILWHIP], :TORRENT),
          test_pokemon(:CHARMANDER, trainers[1], 2001, [:SCRATCH, :GROWL], :BLAZE),
          test_pokemon(:SQUIRTLE, trainers[1], 2002, [:TACKLE, :TAILWHIP], :TORRENT)]
    trainers[0].party = p1[0, 2]
    trainers[1].party = p1[2, 2]
    foe = NPCTrainer.new("Azul QA", :AZUL1)
    foe.id = 300
    enemy = test_pokemon(:CHARMANDER, foe, 3001, [:SCRATCH, :GROWL], :BLAZE)
    # Clone trusted local data: HP, PP and effects of the duplicate are independent.
    p2 = [enemy, Marshal.load(Marshal.dump(enemy))]
    p2[1].personalID = 3002
    raise BattleStopped, "enemy clone aliases moves" if p2[0].moves[0].equal?(p2[1].moves[0])
    foe.party = p2
    scene ||= BattleCreationHelperMethods.create_battle_scene
    local_index = state["participants"].index { |p| p["id"] == @id } * 2
    battle = AnilCoopBattle.new(scene, p1, p2, trainers, [foe], local_index, state["seed"])
    battle_barrier("setup", battle.coop_digest)
    log("2v2 begin owned=#{local_index} temporary_teams=true")
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
    log("2v2 end decision=#{battle.decision} (temporary reward preview discarded; no persistence or story)")
    false
  rescue BattleStopped, StandardError => e
    @last_qa_result = { error: "#{e.class}: #{e.message}", completed: false }
    log("2v2 stopped #{e.class}: #{e.message}\n#{e.backtrace&.first(6)&.join("\n")}")
    pbMessage("Prueba 2v2 detenida: #{e.message}. No se guardaron resultados.") unless @qa_automation
    false
  ensure
    if @active_battle && !@battle_completed
      queue(type: "battle_abort", battle: @active_battle) if connected?
      network
    end
    $player, $PokemonGlobal, $bag, $stats = originals if originals
    @active_battle = @battle_failure = @battle_reply = nil
  end
end

class AnilCoopBattle < Battle
  def initialize(scene, allies, foes, trainers, opponents, local_index, seed)
    @coop_local = local_index
    super(scene, allies, foes, trainers, opponents)
    # Original Añil/LBDSKY map metadata, environment, weather and battle background.
    BattleCreationHelperMethods.prepare_battle(self)
    @party1starts = [0, 2]
    @party2starts = [0]
    setBattleMode("double")
    @internalBattle = @expGain = @moneyGain = @switchStyle = false
    @canLose = true
    @items = [[]]
    @ally_items = [[], []]
    @z_rng = ZCable::BattleRNG.new(seed)
    # Both QA foes originate from one trainer Pokémon. Never award its EXP twice.
    @coop_enemy_origins = [0, 0]
    @coop_defeated = {}
    @coop_rewards_applied = false
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
    return @player[@coop_local / 2] if @coop_reward_owner
    super
  end

  # QA preview only, on temporary teams, after the server has agreed on victory.
  # Persistence needs a durable battle receipt before this can touch saved teams.
  def coop_apply_reward_preview
    return if @coop_rewards_applied || @decision != 1 ||
              !AnilCoop.instance_variable_get(:@battle_completed)
    @coop_rewards_applied = true # Never retry a partially applied local reward.
    @coop_reward_owner = true
    owned = (@coop_local...@coop_local + 2).to_a
    before = @party1.map { |p| [p.exp, p.level] }
    other = @party1.each_index.to_a - owned
    remote_before = Marshal.dump(other.map { |i| @party1[i] })
    @coop_defeated.each_value do |foe|
      eligible = foe.participants.select { |i| owned.include?(i) && @party1[i].able? }
      eligible.each do |i|
        pbGainEVsOne(i, foe)
        pbGainExpOne(i, foe, eligible.length, [], false)
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
  def pbGainMoney; end
  def pbLoseMoney; end

  def pbRunMenu(_index)
    AnilCoop.queue(type: "battle_abort", battle: AnilCoop.instance_variable_get(:@active_battle))
    raise AnilCoop::BattleStopped, "cancelled locally"
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
            @coop_defeated.sort.map { |origin, foe| [origin, foe.participants.sort] }]
    encoded = JSON.generate(AnilCoop.canonical_state(data))
    File.write(File.join(AnilCoopDev::PROFILE, "qa-2v2-state.json"), encoded)
    Digest::SHA256.hexdigest(encoded)
  end

  def coop_order(index)
    return ["none", 0, -1] if @battlers[index].fainted?
    choice = @choices[index]
    case choice[0]
    when :UseMove then ["move", choice[1], choice[3]]
    when :SwitchOut then ["switch", choice[1], -1]
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
      if target >= 0 && !pbMoveCanTarget?(index, target, move.pbTarget(@battlers[index]))
        raise AnilCoop::BattleStopped, "illegal target"
      end
      @choices[index] = [:UseMove, slot, move, target]
    when "switch"
      pbClearChoice(index)
      raise AnilCoop::BattleStopped, "illegal switch" unless pbCanSwitch?(index, slot)
      pbRegisterSwitch(index, slot)
    when "none"
      raise AnilCoop::BattleStopped, "missing order" if pbCanShowCommands?(index)
    else
      raise AnilCoop::BattleStopped, "unknown order"
    end
  end

  def pbCommandPhaseLoop(is_player)
    if is_player
      digest = coop_digest  # before the local menu can register a switch
      super(true)
      packet = AnilCoop.battle_barrier("turn", digest, coop_order(@coop_local), @scene)
      packet["commands"].each_with_index { |order, i| coop_apply(i * 2, order) }
    else
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
    return super if index.odd?
    # The fixture has no pivot moves: replacement is mandatory after fainting.
    digest = coop_digest
    selected = index == @coop_local ? pbPartyScreen(index, check_lax, false) : -1
    packet = AnilCoop.battle_barrier("switch", digest, [index, selected], @scene)
    selected = packet["commands"][index / 2][1]
    raise AnilCoop::BattleStopped, "illegal replacement" unless selected >= 0 && pbCanSwitchIn?(index, selected)
    selected
  end

  def pbEndOfRoundPhase
    super
    AnilCoop.battle_barrier("state", coop_digest, nil, @scene)
  end

  def pbEndOfBattle
    AnilCoop.battle_barrier("result", coop_digest, nil, @scene)
    coop_apply_reward_preview
    super
  end

  def pbStartBattle
    super
  rescue AnilCoop::BattleStopped, StandardError
    AnilCoop.instance_variable_set(:@battle_cleanup, true)
    @decision = 0
    @scene.pbEndBattle(0)
    raise
  end
end

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
