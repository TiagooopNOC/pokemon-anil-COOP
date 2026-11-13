class AnilCoopDuelSelection < AnilCoopTeamSelection
  def initialize
    super(nil, limit: 6, label: "PvP")
  end

  private

  def previous_selection; []; end

  def confirm_team(chosen)
    AnilCoop.pvp_team(chosen)
  end
end

module AnilCoopDuelTransport
  def update_battle_menu
    super
    check_battle_transport! if @pvp_running
  end

  def battle_tick
    super
    return unless @pvp_running && !@battle_completed && !@battle_cleanup && connected?
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) - @pvp_last_pong >= 35
      disconnect
      @battle_failure = "battle_server_silent"
    end
  end

  def receive(message)
    if @pvp_running && message.is_a?(Hash) && message["type"] == "pong"
      @pvp_last_pong = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    super
  end
end
AnilCoop.singleton_class.prepend(AnilCoopDuelTransport)

# Native Singles with Cable Club's mirrored ordering and Co-op's room transport.
class AnilCoopDuel < Battle_CableClub
  def initialize(scene, parties, trainers, owner, seed)
    @client_id = owner
    # Skip Cable Club's socket and AI setup. Both orders arrive through Co-op.
    Battle.instance_method(:initialize).bind(self).call(scene, *parties, [trainers[0]], [trainers[1]])
    setBattleMode("single")
    @internalBattle = @expGain = @moneyGain = @switchStyle = false
    @controlPlayer = false
    @debug = false
    @canLose = true
    @z_rng = ZCable::BattleRNG.new(seed)
    @items = [[]]
    @ally_items = [[]]
    # Use a shared neutral arena. Map/weather from either save must not affect
    # gameplay when the players are standing in different locations.
    @backdrop = "indoor1"
    @showAnims = true
  end

  def pbCanMegaEvolve?(*); false; end
  def pbCanZMove?(*); false; end
  def pbCanDynamax?(*); false; end
  def pbCanTerastallize?(*); false; end
  def pbCanUltraBurst?(*); false; end
  def pbGainExp; end
  def pbGainMoney; end
  def pbLoseMoney; end

  def pbItemMenu(*)
    pbDisplay("La bolsa no está disponible en este duelo.")
    false
  end

  def pbCommandMenu(index, _first_action)
    @scene.pbCommandMenuEx(index, ["¿Qué debería\nhacer #{@battlers[index].name}?",
                                  "Luchar", "Mochila", "Pokémon", "Rendirse"], 0)
  end

  def pbRunMenu(*)
    return false unless pbConfirmMessageSerious("¿Querés rendirte?")
    @forfeit = true
  end

  def canonical_index(index)
    index && index >= 0 ? index ^ @client_id : index
  end

  def canonical_order(values)
    @client_id.zero? ? values : values.reverse
  end

  def decision_for_room
    @client_id == 1 && [1, 2].include?(@decision) ? 3 - @decision : @decision
  end

  def digest
    parties = [@party1, @party2].map do |party|
      party.map do |p|
        [p.species, p.personalID, p.level, p.hp, p.totalhp, p.status, p.statusCount,
         p.form, p.ability_id, p.item_id, p.types, p.attack, p.defense, p.spatk, p.spdef, p.speed,
         p.moves.map { |m| [m.id, m.pp, m.total_pp] }]
      end
    end
    battlers = @battlers.first(2).map do |b|
      next unless b
      effects = b.effects.dup
      [:Attract, :BideTarget, :CounterTarget, :JawLock, :LeechSeed, :LockOnPos,
       :MeanLook, :MirrorCoatTarget, :Octolock, :PerishSongUser, :SkyDrop, :TrappingUser].each do |name|
        next unless PBEffects.const_defined?(name)
        key = PBEffects.const_get(name)
        effects[key] = canonical_index(effects[key]) if effects[key].is_a?(Integer)
      end
      [b.pokemonIndex, b.hp, b.status, b.statusCount, b.stages, effects, b.ability_id, b.item_id,
       b.form, b.types, b.attack, b.defense, b.spatk, b.spdef, b.speed,
       b.moves.map { |m| [m.id, m.pp] }]
    end
    positions = @positions.first(2).map do |position|
      effects = position.effects.dup
      key = PBEffects::FutureSightUserIndex
      effects[key] = canonical_index(effects[key])
      effects
    end
    data = [canonical_order(parties), canonical_order(battlers), @field.effects,
            @field.weather, @field.weatherDuration, @field.terrain, @field.terrainDuration,
            canonical_order(@sides.map(&:effects)), canonical_order(positions), @turnCount, decision_for_room]
    Digest::SHA256.hexdigest(JSON.generate(AnilCoop.canonical_state(data)))
  end

  def local_order
    return ["forfeit", 0, -1] if @forfeit
    action, slot, move, target = @choices[0]
    case action
    when :UseMove
      rule = move.pbTarget(@battlers[0])
      target = -1 if rule.num_targets == 0 || rule.id == :RandomNearFoe
      ["move", slot, canonical_index(target)]
    when :SwitchOut then ["switch", slot, -1]
    when :None then ["none", 0, -1]
    else raise AnilCoop::BattleStopped, "orden no compatible"
    end
  end

  def apply_order(index, order)
    action, slot, target = order
    if action != "none" && !pbCanShowCommands?(index)
      raise AnilCoop::BattleStopped, "orden inesperada para este Pokémon"
    end
    case action
    when "move"
      b = @battlers[index]
      move = slot < 0 ? @struggle : b.moves[slot]
      legal = slot < 0 ? !pbCanChooseAnyMove?(index) : pbCanChooseMove?(index, slot, false)
      raise AnilCoop::BattleStopped, "movimiento no válido" unless legal && move
      rule = move.pbTarget(b)
      target = canonical_index(target)
      if target >= 0 && (rule.num_targets == 0 || rule.id == :RandomNearFoe ||
                        !pbMoveCanTarget?(index, target, rule))
        raise AnilCoop::BattleStopped, "objetivo no válido"
      end
      @choices[index] = [:UseMove, slot, move, target]
    when "switch"
      pbClearChoice(index)
      raise AnilCoop::BattleStopped, "cambio no válido" unless pbCanSwitch?(index, slot)
      pbRegisterSwitch(index, slot)
    when "none"
      raise AnilCoop::BattleStopped, "falta la orden" if pbCanShowCommands?(index)
    end
  end

  def pbCanShowCommands?(index)
    # Cable Club forces its remote AI hook to run. Co-op receives orders itself.
    Battle.instance_method(:pbCanShowCommands?).bind(self).call(index)
  end

  def pbCommandPhaseLoop(is_player)
    return unless is_player
    AnilCoop.speed_battle_enforce
    state = digest
    packet = AnilCoop.battle_barrier("turn", state, choose_local_order, @scene)
    orders = packet.fetch("commands")
    if orders.all? { |order| order[0] == "forfeit" }
      @decision = 5
    elsif (loser = orders.index { |order| order[0] == "forfeit" })
      @decision = loser == @client_id ? 2 : 1
    else
      canonical_order(orders).each_with_index { |order, index| apply_order(index, order) }
      @z_rng = ZCable::BattleRNG.new(packet.fetch("seed"))
    end
  end

  def choose_local_order
    # Resolve the original human command loop, never Cable Club's remote AI.
    Battle.instance_method(:pbCommandPhaseLoop).bind(self).call(true)
    local_order
  end

  def pbSwitchInBetween(index, check_lax = false, can_cancel = false)
    AnilCoop.speed_battle_enforce
    owner = canonical_index(index)
    state = digest
    selected = index == 0 ? pbPartyScreen(index, check_lax, can_cancel) : -1
    packet = AnilCoop.battle_barrier("switch", state, [owner, selected], @scene)
    selected = packet.fetch("commands").fetch(owner)[1]
    return -1 if can_cancel && selected == -1
    raise AnilCoop::BattleStopped, "sustitución no válida" unless selected >= 0 && pbCanSwitchIn?(index, selected)
    selected
  end

  def pbEndOfRoundPhase
    super
    AnilCoop.battle_barrier("state", digest, nil, @scene)
  end

  def pbEndOfBattle
    AnilCoop.battle_barrier("result", digest, nil, @scene)
    super
  end
end

module AnilCoop
  def self.pvp_enabled?; ENV["ANIL_COOP_PVP"] == "1"; end
  def self.pvp_preparing?; !!@pvp_offer; end

  def self.pvp_team(chosen)
    chosen.map do |index|
      pokemon = $player.party.fetch(index)
      snapshot = team_snapshot(pokemon, index)
      raise BattleStopped, "#{pokemon.name} tiene una forma que no se puede sincronizar." unless
        GameData::Species.get_species_form(pokemon.species, pokemon.form).form == pokemon.form
      copy = team_pokemon(snapshot)
      unless team_snapshot(copy, index) == snapshot && copy.species_data.id == pokemon.species_data.id
        raise BattleStopped, "#{pokemon.name} tiene atributos que no se pueden sincronizar."
      end
      snapshot
    rescue StandardError => error
      raise BattleStopped, "Pokémon incompatible: #{error.message}"
    end
  end

  def self.pvp_receive(message)
    return unless pvp_enabled?
    case message["type"]
    when "pvp_prepare"
      @pvp_offer = message if message.fetch("players").include?(@id)
    when "pvp_start"
      @pvp_start = message if message["battle"] == @active_battle
    when "pvp_cancel"
      @pvp_unavailable = "Uno de los jugadores ya está en combate."
    when "battle_abort"
      if @pvp_offer && @pvp_offer["battle"] == message["battle"]
        @pvp_offer = nil
        @pvp_unavailable = "El desafío se canceló antes de empezar."
      end
    end
  end

  def self.pvp_poll
    return unless pvp_enabled? && connected? && online_available? && !@invite_modal && !@pvp_running &&
                  !$game_temp.in_menu && !@online_screen_active && !$game_temp.message_window_showing &&
                  !$game_temp.player_transferring && !@team_menu_active
    if @pvp_unavailable
      message, @pvp_unavailable = @pvp_unavailable, nil
      pbMessage(message) { battle_tick }
    elsif @pvp_offer
      offer, @pvp_offer = @pvp_offer, nil
      run_duel(offer)
    end
  end

  def self.choose_pvp_team
    AnilCoopDuelSelection.new.run
  end

  def self.pvp_trade_safe?
    Dir.glob(File.join(AnilCoopDev::PROFILE, "**", "*")).none? do |file|
      File.basename(file).match?(/trade|intercambio/i)
    end
  end

  def self.run_duel(offer)
    @pvp_running = true
    @pvp_last_pong = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @last_pvp_result = nil
    @active_battle = offer.fetch("battle")
    @battle_seq = 0
    @battle_completed = @battle_cleanup = false
    @battle_failure = @pvp_start = nil
    speed_battle_enter
    raise BattleStopped, "Hay datos de intercambio pendientes en el perfil." unless pvp_trade_safe?
    team = choose_pvp_team
    return unless team
    queue(type: "pvp_ready", battle: @active_battle, team: team, trainer: trainer_snapshot)
    unless @qa_pvp
      waiting = Window_AdvancedTextPokemon.new("Equipo listo. Esperando al rival… (X para cancelar)")
      waiting.width = Graphics.width
      waiting.y = Graphics.height - waiting.height
      waiting.z = 99999
    end
    until @pvp_start
      battle_tick
      check_battle_transport!
      return if Input.trigger?(Input::BACK)
      Graphics.update
      Input.update
      waiting&.update
    end
    waiting&.dispose
    waiting = nil
    start = @pvp_start
    owner = start.fetch("players").index(@id)
    entries = start.fetch("teams")
    raise BattleStopped, "El equipo cambió durante la espera." unless entries.fetch(owner).fetch("team") == team
    entries = entries.reverse if owner == 1
    originals = [$player, $PokemonGlobal, $bag, $stats, $game_switches, $game_variables,
                 $game_self_switches, $game_system, $PokemonSystem, $randomized_data]
    $player, $PokemonGlobal, $bag, $stats, $game_switches, $game_variables,
      $game_self_switches, $game_system, $PokemonSystem, $randomized_data = Marshal.load(Marshal.dump(originals))
    # Snapshots already contain the effective values. Never randomize them again
    # using a replica's personal settings when constructing or using them.
    $PokemonGlobal.random_enabled = false if $PokemonGlobal.respond_to?(:random_enabled=)
    $PokemonGlobal.challenge_started = false if $PokemonGlobal.respond_to?(:challenge_started=)
    $PokemonGlobal.challenge_encs ||= {} if $PokemonGlobal.respond_to?(:challenge_encs)
    parties = entries.map { |entry| entry.fetch("team").map { |pokemon| team_pokemon(pokemon) } }
    trainers = entries.map do |entry|
      data = entry.fetch("trainer")
      raise BattleStopped, "Entrenador incompatible." unless GameData::TrainerType.exists?(data["trainer_type"])
      NPCTrainer.new(data["name"], data["trainer_type"].to_sym).tap { |t| t.id, t.language = data.values_at("id", "language") }
    end
    trainers.each_with_index { |trainer, i| trainer.party = parties[i] }
    $player.party = parties[0]
    scene = BattleCreationHelperMethods.create_battle_scene
    battle = AnilCoopDuel.new(scene, parties, trainers, owner, start.fetch("seed"))
    @battle_context = battle
    battle_barrier("setup", battle.digest)
    battle_error = nil
    pbBattleAnimation(pbGetTrainerBattleBGM([trainers[1]]), 1, [trainers[1]]) do
      pbSceneStandby do
        begin
          battle.pbStartBattle
        rescue StandardError => error
          battle_error = error
          @battle_cleanup = true
          close_battle_menus
          scene.pbEndBattle(0) rescue nil
        end
      end
    end
    raise battle_error if battle_error
    @last_pvp_result = { decision: battle.decision, turns: battle.turnCount, complete: @battle_completed }
    result = { 1 => "Victoria", 2 => "Derrota", 5 => "Empate" }.fetch(battle.decision, "Duelo terminado")
  rescue StandardError => error
    @last_pvp_result = { error: error.message, complete: false }
    log("PvP: #{error.class}: #{error.message}\n#{error.backtrace.first(8).join("\n")}")
    result = "Duelo cancelado. #{error.message}"
    result = case error.message
             when "battle_disconnect", "connection lost" then "Duelo cancelado por desconexión."
             when "battle_server_silent" then "Duelo cancelado porque el servidor dejó de responder."
             when "battle_desync" then "Duelo cancelado porque los estados de ambos juegos no coincidieron."
             when "battle_cancelled" then "El rival canceló el duelo."
             else result
             end
  ensure
    waiting&.dispose
    if @active_battle && !@battle_completed && connected?
      queue(type: "battle_abort", battle: @active_battle)
      network
    end
    if originals
      $player, $PokemonGlobal, $bag, $stats, $game_switches, $game_variables,
        $game_self_switches, $game_system, $PokemonSystem, $randomized_data = originals
    end
    @active_battle = @battle_reply = @battle_failure = @pvp_start = @battle_context = nil
    @battle_phase = @battle_status_logged_at = nil
    speed_battle_exit
    @pvp_running = false
    pbMessage(result) { battle_tick } if result && !@qa_pvp
  end
end
