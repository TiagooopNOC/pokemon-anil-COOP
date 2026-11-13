module AnilPvpQaMessages
  def pbDisplayPausedMessage(message); pbDisplayMessage(message); end
  def pbDisplayMessage(message, brief = false, &block); AnilCoop.log("PvP QA text #{message}"); block&.call; end
end
Battle::Scene.prepend(AnilPvpQaMessages)
module AnilPvpQaBattle
  attr_reader :qa_rounds
  QA_MOVES = {
    "weather" => [[:RAINDANCE, :SUNNYDAY, :SANDSTORM, :SNOWSCAPE], [:SPLASH]],
    "status" => [[:THUNDERWAVE, :WILLOWISP, :TOXIC, :SPORE], [:SPLASH]],
    "priority" => [[:QUICKATTACK, :PROTECT, :FLY, :GROWL], [:TACKLE, :SPLASH]],
    "draw" => [[:PERISHSONG, :SPLASH], [:SPLASH]],
    "ability" => [[:SPLASH], [:SPLASH]],
    "ability_out" => [[:SPLASH], [:SPLASH]],
    "freeze" => [[:SPLASH], [:SPLASH]],
    "form" => [[:THUNDERSHOCK], [:SPLASH]],
  }.freeze

  def pbCommandMenu(*)
    mode = ENV["ANIL_PVP_QA_MODE"]
    if mode == "exit" && @client_id == 1 && @turnCount >= 1
      File.write(File.join(AnilCoopDev::PROFILE, "qa-pvp-result.json"), JSON.generate(exited: true))
      Process.exit!(0)
    end
    return 2 if (@turnCount == 0 && ((mode == "switch" && @client_id == 1) || mode == "both_switch")) ||
                (mode == "ability_out" && @client_id == 0 && @turnCount == 1) ||
                (mode == "status" && @client_id == 1 && (1..3).cover?(@turnCount))
    short_case = %w[ability_out both_switch wait restart].include?(mode)
    scripted_case = QA_MOVES.key?(mode) && mode != "draw"
    if @client_id == 1 && ((short_case && @turnCount >= 2) || (scripted_case && @turnCount >= 5))
      @forfeit = true
      return 3
    end
    0
  end

  def pbRunMenu(*); @forfeit; end

  def pbFightMenu(index)
    AnilCoop.log("PvP QA input #{@turnCount}")
    if @turnCount == 0
      raise "PvP did not lock speed" unless $GameSpeed == 0 && !$CanToggle
      bitmap = Graphics.snap_to_bitmap
      bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-pvp-battle.png"))
      bitmap.dispose
    end
    if ENV["ANIL_PVP_QA_MODE"] == "disconnect" && @client_id == 1 && @turnCount >= 1
      AnilCoop.disconnect
      raise AnilCoop::BattleStopped, 'QA transport closed'
    end
    mode = ENV["ANIL_PVP_QA_MODE"]
    if mode == "silent" && @turnCount.zero?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        @scene.pbUpdate
      end
      raise "silent server was not detected"
    end
    if mode == "wait" && @client_id == 1 && @turnCount == 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 125
        @scene.pbUpdate
      end
    end
    if (moves = QA_MOVES[mode])
      slot = if mode == "draw" && @client_id == 0
               @turnCount.zero? ? 0 : 1
             elsif @client_id == 0
               @turnCount % moves[0].length
             else
               0
             end
      return pbRegisterMove(index, slot)
    end
    pbRegisterMove(index, @turnCount == 1 ? 1 : 0)
  end

  def pbPartyScreen(index, _check_lax = false, _can_cancel = false, register = false)
    if ENV["ANIL_PVP_QA_MODE"] == "switch"
      slot = pbParty(index).each_index.find { |i| pbCanSwitchIn?(index, i) }
      raise "missing QA replacement" unless slot
      start = pbTeamIndexRangeFromBattlerIndex(index)[0]
      @qa_native_party = pbPartyOrder(index).fetch(slot) - start
      begin
        return super
      ensure
        @qa_native_party = nil
      end
    end
    choices = (0...pbParty(index).length).select { |slot| pbCanSwitchIn?(index, slot) }
    selected = if ENV["ANIL_PVP_QA_MODE"] == "status" && register
                 choices.find { |slot| slot == @turnCount } || -1
               else
                 choices.first || -1
               end
    pbRegisterSwitch(index, selected) if register && selected >= 0
    selected
  end
  def pbDisplayPaused(message, &block); @scene.pbDisplayMessage(message, &block); end

  def pbEndOfRoundPhase
    super
    (@qa_rounds ||= []) << { weather: @field.weather, sides: canonical_order(@battlers.first(2).map do |b|
      [b.status, b.pokemonIndex, b.hp, b.stages[:ATTACK], b.effects[PBEffects::TwoTurnAttack],
       b.ability_id, b.item_id, b.form]
    end) }
    @qa_rounds.last[:party_hp] = canonical_order([@party1, @party2]).map { |party| party.map(&:hp) }
    AnilCoop.log("PvP QA state turn=#{@turnCount} weather=#{@field.weather} " \
                 "battlers=#{canonical_order(@battlers.map { |b| [b.status, b.pokemonIndex] }).inspect}")
  end

  def pbAttackPhase
    if ENV["ANIL_PVP_QA_MODE"] == "animation_disconnect" && @client_id == 1 && @turnCount == 0
      @qa_drop_after_animation = true
    end
    super
  ensure
    @qa_drop_after_animation = false
  end

  def pbAnimation(*)
    # Drop the connection from inside the scene update of a real attack animation.
    if @qa_drop_after_animation
      @scene.instance_variable_set(:@pvp_qa_drop_transport, true)
    end
    super
  ensure
    @scene.instance_variable_set(:@pvp_qa_drop_transport, false)
  end
end
AnilCoopDuel.prepend(AnilPvpQaBattle)

module AnilPvpQaNativeParty
  def pbChoosePokemon(*)
    slot = AnilCoop.instance_variable_get(:@battle_context)&.instance_variable_get(:@qa_native_party)
    return super unless slot
    update
    Graphics.update
    bitmap = Graphics.snap_to_bitmap
    bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-pvp-switch.png"))
    slot
  ensure
    bitmap&.dispose
  end

  def pbShowCommands(*)
    return super unless AnilCoop.instance_variable_get(:@battle_context)&.instance_variable_get(:@qa_native_party)
    0
  end
end
PokemonParty_Scene.prepend(AnilPvpQaNativeParty)

module AnilPvpQaAnimationDrop
  def pbUpdate(*)
    super
    return unless @pvp_qa_drop_transport
    @pvp_qa_drop_transport = false
    AnilCoop.disconnect
    raise AnilCoop::BattleStopped, "QA transport closed"
  end
end
Battle::Scene.prepend(AnilPvpQaAnimationDrop)

module AnilPvpQaEvidence
  def pbEndOfBattle
    result = super
    AnilCoop.instance_variable_set(:@qa_pvp_rounds, qa_rounds || [])
    result
  end
end
AnilCoopDuel.prepend(AnilPvpQaEvidence)

module AnilPvpQaSelection
  def pbChoosePokemon(*)
    if ENV["ANIL_PVP_QA_MODE"] == "selection_disconnect" && ENV["ANIL_COOP_MODE"] == "join"
      AnilCoop.disconnect
      raise AnilCoop::BattleStopped, "QA transport closed"
    end
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

def pvp_qa_state
  {
    "party" => $player.party.each_with_index.map { |p, i| AnilCoop.team_snapshot(p, i) },
    "money" => $player.money,
    "badges" => $player.badges,
    "bag" => Digest::SHA256.hexdigest(Marshal.dump($bag)),
    "switches" => Digest::SHA256.hexdigest(Marshal.dump($game_switches)),
    "variables" => Digest::SHA256.hexdigest(Marshal.dump($game_variables)),
    "self_switches" => Digest::SHA256.hexdigest(Marshal.dump($game_self_switches)),
    "challenge" => [$PokemonGlobal.challenge_started, $PokemonGlobal.challenge_lives,
                    $PokemonGlobal.challenge_rules, $PokemonGlobal.challenge_encs,
                    $PokemonGlobal.challenge_state, $player.party.map { |p| !!p.perma_faint }],
    "random" => [$PokemonGlobal.random_enabled, $PokemonGlobal.enable_random_types,
                 $PokemonGlobal.random_types, $player.party.map(&:randomized?)]
  }
end

def pvp_qa_differences(expected, actual)
  expected.each_with_object({}) do |(key, value), differences|
    differences[key] = [value, actual[key]] if value != actual[key]
  end
end

trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  trace.disable
  report = {}
  begin
    mode, role = ENV.values_at("ANIL_PVP_QA_MODE","ANIL_COOP_MODE")
    phase = ENV["ANIL_PVP_QA_PHASE"]
    ENV.delete("ANIL_COOP_SESSION") unless phase == "duel"
    fixture = File.join(AnilCoopDev::PROFILE, "qa-pvp-before.json")
    save = SaveData.get_full_path(phase == "reload" ? "Partida 2" : "Partida 1")
    if phase == "create"
      Game.start_new
      $player.name = ENV.fetch("ANIL_COOP_NAME")
    else
      raise "fixture save missing" unless File.file?(save)
      data = SaveData.get_data_from_file(save)
      SaveData.load_bootup_values(data)
      Game.load(data)
      if $PokemonGlobal.challenge_started
        ChallengeModes.begin_challenge
        raise "challenge inactive after restart" unless ChallengeModes.on?(:PERMAFAINT)
      end
    end
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    before = Digest::SHA256.file(save).hexdigest
    if %w[reload verify].include?(phase)
      actual = JSON.parse(JSON.generate(pvp_qa_state))
      expected = JSON.parse(File.read(fixture))
      differences = pvp_qa_differences(expected, actual)
      report[:cold_reload] = differences.empty?
      report[:differences] = differences unless differences.empty?
      next
    end
    strong = %w[guest randomlocke].include?(mode) ? role == "join" : role == "create"
    side = role == "create" ? 0 : 1
    count = %w[switch both_switch ability_out].include?(mode) ? 2 : mode == "status" && side == 1 ? 4 : 1
    if phase == "create"
      random = mode == "random_both" || (mode == "random" && side == 1) ||
               (mode == "randomlocke" && side == 0)
      $PokemonGlobal.random_enabled = random
      $PokemonGlobal.enable_random_types = random
      $PokemonGlobal.random_types = { BULBASAUR: [:WATER, :FLYING] } if random
      $player.party = Array.new(count) do |i|
        moves = AnilPvpQaBattle::QA_MOVES.fetch(mode, [[:TACKLE, :GROWL], [:TACKLE, :GROWL]])[side]
        species = mode == "form" ? :ROTOM : mode == "status" ? :RATTATA : :BULBASAUR
        ability = case mode
                  when "ability" then [:DRIZZLE, :DROUGHT][side]
                  when "ability_out" then :REGENERATOR
                  when "status" then :NOGUARD
                  when "form" then :LEVITATE
                  else :OVERGROW
                  end
        p = AnilCoop.test_pokemon(species, $player, (side.zero? ? 10 : 20) + i, moves, ability)
        p.form_simple = 1 if mode == "form"
        if random
          p.randomized = true
          p.ability = p.forced_ability = :TORRENT
          p.item = :ORANBERRY
          p.moves[0] = Pokemon::Move.new(:WATERGUN)
          raise "random types inactive" unless p.types == [:WATER, :FLYING]
        end
        p.level = strong ? 14 : 10
        p.calc_stats
        p.heal
        p.hp = p.totalhp / 2 if mode == "ability_out" && side == 0 && i == 0
        p.item = :ORANBERRY if mode == "switch"
        if mode == "freeze" && side == 1
          p.status = Settings::FREEZE_EFFECTS_CAUSE_FROSTBITE ? :FROSTBITE : :FROZEN
        end
        p
      end
      if (mode == "nuzlocke" && side == 1) || (mode == "randomlocke" && side == 0)
        $PokemonGlobal.challenge_rules = [:PERMAFAINT, :FIRST_CAPTURE, :MODOVIDAS]
        $PokemonGlobal.challenge_lives = 2
        $PokemonGlobal.challenge_encs = { $game_map.map_id => true }
        ChallengeModes.begin_challenge
      end
    end
    if phase == "create"
      raise "fixture save failed" unless Game.save("Partida 1")
      File.write(fixture, JSON.generate(pvp_qa_state))
      report[:created] = true
      next
    end
    logical = JSON.parse(JSON.generate(pvp_qa_state))
    differences = pvp_qa_differences(JSON.parse(File.read(fixture)), logical)
    report[:differences] = differences unless differences.empty?
    raise "pre-duel cold reload differs" unless differences.empty?
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
      report[:rounds] = AnilCoop.instance_variable_get(:@qa_pvp_rounds)
    end
    if report[:complete]
      remote = AnilCoop.instance_variable_get(:@peers).keys.first
      previous = AnilCoop.instance_variable_get(:@peers).dig(remote, "position", "seq").to_i
      wait.call do
        AnilCoop.tick($scene)
        AnilCoop.instance_variable_get(:@peers).dig(remote, "position", "seq").to_i > previous
      end
      until_time = System.uptime + 2
      while System.uptime < until_time
        AnilCoop.tick($scene)
        Graphics.update
      end
      report[:position_after] = true
    end
    report[:connected] = AnilCoop.connected?
    report[:originals] = [$player, $PokemonGlobal, $bag, $stats].zip(original).all? { |a,b| a.equal?(b) } && $player.party.each_with_index.map { |p,i| AnilCoop.team_snapshot(p,i) } == party
    report[:save_intact] = Digest::SHA256.file(save).hexdigest == before
    report[:map_restored] = $scene.is_a?(Scene_Map) && !$game_temp.in_battle
    report[:logical_intact] = JSON.parse(JSON.generate(pvp_qa_state)) == logical
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
if ENV["ANIL_PVP_QA_MODE"] == "brock" && ENV["ANIL_PVP_QA_PHASE"] == "duel"
  ENV["ANIL_COOP_QA_BOT"] = "engine"
  ENV["ANIL_COOP_QA_SCENARIO"] = "story-brock"
  ENV["ANIL_COOP_BATTLES"] = "1"
  ENV["ANIL_COOP_PERSONAL_TEAM"] = "1"
  load "CoopDev/battle_qa.rb"
else
  trace.enable
end
