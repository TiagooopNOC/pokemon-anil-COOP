# Presence prototype: only trainer coordinates cross the network; wild battles stay local.
require "socket"
require "json"

class AnilCoopRemoteCharacter < Game_Character
  def name; ""; end
end

module AnilCoop
  @peers = {}
  @sprites = {}
  @trainer_states = {}
  @sequence = 0
  @buffer = +""
  @out = +""
  @last_send = 0.0
  @last_ping = 0.0
  @last_connect = 0.0
  @map = nil

  def self.log(message)
    File.open(File.join(AnilCoopDev::PROFILE, "coop.log"), "a") { |f| f.puts("#{Time.now.utc} #{message}") }
  rescue StandardError
  end

  def self.connect
    return if @socket || !ENV["ANIL_COOP_SESSION"]
    now = Time.now.to_f
    return if now - @last_connect < 3
    @last_connect = now
    port = Integer(ENV["ANIL_COOP_PORT"] || "0")
    return unless port.between?(1, 65535)
    @socket = Socket.tcp("127.0.0.1", port, connect_timeout: 1)
    @buffer = +""
    @out = +""
    role = @resume ? "join" : (ENV["ANIL_COOP_MODE"] == "create" ? "create" : "join")
    hello = { type: role, session: ENV["ANIL_COOP_SESSION"], name: ENV["ANIL_COOP_NAME"] || "Player" }
    hello[:resume] = @resume if @resume
    queue(hello)
    log("connected transport, mode=#{role}")
  rescue StandardError => e
    log("connect error #{e.class}: #{e.message}")
    disconnect
  end

  def self.queue(message)
    @out << JSON.generate(message) << "\n"
  end

  def self.connected?
    !!(@socket && @id)
  end

  def self.qa_trainer
    return unless ENV["ANIL_COOP_QA_TRAINER"] == "1" && @id
    sprite_name = $game_player.character_name.to_s
    return if sprite_name.empty?  # The player graphic may not be ready on first map frame.
    @qa_trainer_anchor ||= [$game_map.map_id, $game_player.x + 1, $game_player.y]
    return if @qa_trainer_anchor[0] != $game_map.map_id
    event_id = 9000
    if (existing = $game_map.events[event_id])
      existing.character_name = sprite_name if existing.character_name.to_s.empty?
      sprites = $scene.spriteset.character_sprites
      unless sprites.any? { |s| !s.disposed? && s.character.equal?(existing) }
        sprites.push(Sprite_Character.new(Spriteset_Map.viewport, existing))
      end
      return
    end
    _, x, y = @qa_trainer_anchor
    event = RPG::Event.new(x, y)
    event.id = event_id
    event.name = "trainer(1) Co-op QA"
    page = event.pages[0]
    page.trigger = 0
    page.graphic.character_name = sprite_name
    page.graphic.character_hue = 120
    Compiler.push_script(page.list, 'TrainerBattle.start(:AZUL1, "Azul", 1)')
    Compiler.push_end(page.list)
    game_event = Game_Event.new($game_map.map_id, event, $game_map)
    $game_map.events[event_id] = game_event
    $scene.spriteset.character_sprites.push(Sprite_Character.new(Spriteset_Map.viewport, game_event))
    log("qa trainer map=#{$game_map.map_id} event=#{event_id} x=#{x} y=#{y} sprite=#{sprite_name}")
  rescue StandardError => e
    log("qa trainer error #{e.class}: #{e.message}")
  end

  def self.qa_provision
    species = ENV["ANIL_COOP_QA_STARTER"]
    return unless species && @id && !@qa_provisioned
    @qa_provisioned = true
    if !$player.party.empty?
      log("qa provision skipped: existing party")
      return
    end
    pbAddPokemonSilent(species.to_sym, 7)
    $bag.add(:POKEBALL, 20)
    if ENV["ANIL_COOP_QA_RANDOMLOCKE"] == "1" && !RandomizedChallenge.enabled?
      RandomizedChallenge.enable
      $PokemonGlobal.challenge_rules = [:PERMAFAINT, :ONE_CAPTURE]
      ChallengeModes.begin_challenge
    end
    saved = Game.save("Partida 1")
    log("qa provision species=#{$player.party[0]&.species} random=#{RandomizedChallenge.enabled?} locke=#{ChallengeModes.on?} saved=#{saved}")
  rescue StandardError => e
    log("qa provision error #{e.class}: #{e.message}")
  end

  def self.disconnect
    @battle_failure = "connection lost" if @active_battle
    @socket&.close rescue nil
    @socket = nil
    @id = nil
    @peers.clear
    @trainer_states.clear
    clear_sprites
    log("disconnected")
  end

  def self.clear_sprites
    @sprites.each_value { |s| s.dispose unless s.disposed? }
    @sprites.clear
  end

  def self.receive(message)
    return unless message.is_a?(Hash)
    case message["type"]
    when "welcome"
      @id = message["id"]
      @resume = message["resume"]
      @slot = message["slot"]
      @peers.clear
      Array(message["peers"]).each { |p| @peers[p["id"]] = p if p.is_a?(Hash) && p["id"].is_a?(String) }
      log("welcome slot=#{@slot} peers=#{@peers.length}")
    when "enter", "position"
      p = message["player"]
      @peers[p["id"]] = p if p.is_a?(Hash) && p["id"].is_a?(String) && p["id"] != @id
      log("peer #{message["type"]} slot=#{p["slot"]}") if p.is_a?(Hash) && message["type"] == "enter"
    when "leave"
      @peers.delete(message["id"])
      if (sprite = @sprites.delete(message["id"]))
        sprite.dispose unless sprite.disposed?
      end
      log("peer left #{message["id"]}")
    when "trainer_state"
      @trainer_states[[message["map"], message["event"]]] = message
      log("trainer state map=#{message["map"]} event=#{message["event"]} phase=#{message["phase"]} players=#{message["participants"].length}")
    when "trainer_closed"
      @trainer_states.delete([message["map"], message["event"]])
    when "battle_step", "battle_abort"
      battle_receive(message) if respond_to?(:battle_receive)
    when "error"
      log("server error #{message["reason"]}")
      if message["reason"].to_s.start_with?("battle_")
        @battle_failure = message["reason"] if @active_battle
      elsif message["reason"].to_s.start_with?("trainer_") || message["reason"] == "coop_battle_pending"
        @trainer_error = message["reason"]
      else
        disconnect
      end
    end
  end

  def self.network
    return unless @socket
    unless @out.empty?
      sent = @socket.write_nonblock(@out, exception: false)
      @out = @out.byteslice(sent..-1) || +"" if sent.is_a?(Integer)
    end
    loop do
      chunk = @socket.read_nonblock(4096, exception: false)
      break if chunk == :wait_readable
      raise EOFError if chunk.nil? || chunk.empty?
      @buffer << chunk
      raise "oversize network message" if @buffer.bytesize > 65536
      while (index = @buffer.index("\n"))
        line = @buffer.slice!(0..index)
        receive(JSON.parse(line))
        return unless @socket
      end
    end
  rescue StandardError => e
    log("network error #{e.class}: #{e.message}")
    disconnect
  end

  # Battle runs inside the same game process but stops Scene_Map updates.
  # Keep the last map position alive while this player's battle remains local.
  def self.battle_tick
    return unless ENV["ANIL_COOP_SESSION"] && $game_map
    connect
    network
    now = Time.now.to_f
    if @socket && @id && now - @last_ping >= 10
      @last_ping = now
      queue(type: "ping")
    end
  end

  def self.qa_wild_ready?
    return false unless ENV["ANIL_COOP_QA_WILD"] == "1" && @id && !@qa_wild_started
    @peers.values.any? { |peer| peer["position"].is_a?(Hash) && peer["position"]["map"] == $game_map.map_id }
  end

  def self.qa_wild
    @qa_wild_started = true
    temporary_pokemon = nil
    if $player.able_pokemon_count == 0
      temporary_pokemon = Pokemon.new(:BULBASAUR, 7)
      $player.party << temporary_pokemon
    end
    first = $player.party[0]
    log("qa wild begin party=#{first&.species} level=#{first&.level} exp=#{first&.exp} count=#{$player.party.length} random=#{RandomizedChallenge.enabled?} locke=#{ChallengeModes.on?}")
    result = WildBattle.start(:RATTATA, 3)
    first = $player.party[0]
    log("qa wild end result=#{result} party=#{first&.species} level=#{first&.level} exp=#{first&.exp} count=#{$player.party.length}")
  rescue StandardError => e
    log("qa wild error #{e.class}: #{e.message}")
  ensure
    $player.party.delete(temporary_pokemon) if temporary_pokemon
  end

  def self.trainer_send(type, event, extra = {})
    queue({ type: type, map: event.map_id, event: event.id }.merge(extra))
    network
  end

  def self.trainer_wait_for(event, phase = nil)
    deadline = Time.now.to_f + 5
    loop do
      Graphics.update
      Input.update
      network
      state = @trainer_states[[event.map_id, event.id]]
      return state if state && (!phase || state["phase"] == phase)
      return nil if !@socket || @trainer_error || Time.now.to_f >= deadline
    end
  end

  def self.start_qa_battle(state)
    # Development fixture only: reload between attempts, never during a battle.
    load "CoopDev/coop_battle.rb" if qa_2v2?
    qa_coop_battle(state)
  end

  def self.trainer_lobby(event, forced, trainer_args = nil)
    key = [event.map_id, event.id]
    @trainer_states.delete(key)
    @trainer_error = nil
    @pending_foe = nil
    extras = { forced: forced }
    extras[:prototype] = battle_prototype if respond_to?(:qa_2v2?) && qa_2v2? && (personal_team? || event.id == 9000)
    if personal_team? && trainer_args
      extras[:encounter_key] = trainer_identity(event, trainer_args)
      if trainer_completed?(extras[:encounter_key])
        pbMessage("Ya derrotaste a este entrenador en tu partida.") { network }
        return false
      end
    end
    trainer_send("trainer_wait", event, extras)
    state = trainer_wait_for(event, "pending")
    return yield if !state && forced
    return false if !state
    loop do
      network
      state = @trainer_states[key]
      return forced ? yield : false if !state
      me = state["participants"].find { |p| p["id"] == @id }
      return forced ? yield : false if !me
      return start_qa_battle(state) if state["phase"] == "locked" && state["battle"]
      return forced ? yield : false if state["phase"] != "pending"
      host = state["host"] == @id
      lines = state["participants"].map { |p| "#{p["name"]}: #{p["ready"] ? "listo" : "esperando"} (#{p["team_count"] || 0})" }
      commands = [me["ready"] ? "No estoy listo" : "Estoy listo", "Actualizar"]
      commands += ["Confirmar con listos", "Combatir solo"] if host
      commands << "Elegir Pokémon" if personal_team?
      commands << (forced ? "Seguir esperando" : "Salir de la espera")
      choice = pbMessage("Entrenador en espera.\n#{lines.join(" / ")}", commands, -1) { network }
      next if @trainer_states[key] && @trainer_states[key]["phase"] != "pending"
      if personal_team? && choice == commands.length - 2
        choose_team(event)
      elsif choice == 0
        next if personal_team? && !me["ready"] && me.fetch("team_count", 0) == 0 && !choose_team(event)
        trainer_send("trainer_ready", event, ready: !me["ready"])
      elsif choice == 1
        next
      elsif host && (choice == 2 || choice == 3)
        solo = choice == 3
        @trainer_error = nil
        if !solo && personal_team? && trainer_args
          begin
            send_trainer_foe(event, trainer_args)
          rescue StandardError => e
            pbMessage(e.message) { network }
            next
          end
        end
        trainer_send("trainer_start", event, solo: solo)
        locked = trainer_wait_for(event, "locked")
        if locked && locked["participants"].any? { |p| p["id"] == @id }
          return start_qa_battle(locked) if locked["battle"]
          log("trainer solo start map=#{event.map_id} event=#{event.id}")
          begin
            won = yield
            if won && extras[:encounter_key]
              $PokemonGlobal.anil_coop_trainers ||= {}
              $PokemonGlobal.anil_coop_trainers[extras[:encounter_key]] = true
            end
            return won
          ensure
            trainer_send("trainer_finish", event) if @socket
          end
        end
        pbMessage("Combate cooperativo pendiente. El grupo queda preparado para la siguiente fase.") if @trainer_error == "coop_battle_pending"
      elsif !forced && (choice == commands.length - 1 || choice == -1)
        trainer_send("trainer_cancel", event)
        @trainer_states.delete(key)
        return false
      end
    end
  end

  def self.tick(scene)
    return unless ENV["ANIL_COOP_SESSION"] && $game_player && $game_map
    connect
    network
    now = Time.now.to_f
    if @socket && @id && now - @last_send >= 0.12
      @last_send = now
      sprite_name = $game_player.character_name.to_s
      unless sprite_name.empty?
        @sequence += 1
        queue(type: "position", map: $game_map.map_id, x: $game_player.x,
              y: $game_player.y, direction: $game_player.direction,
              pattern: $game_player.pattern, sprite: sprite_name, seq: @sequence)
      end
    end
    if @map != $game_map.map_id
      clear_sprites
      @map = $game_map.map_id
    end
    @peers.each do |id, peer|
      pos = peer["position"]
      if !pos.is_a?(Hash) || pos["map"] != @map || pos["sprite"].to_s.empty?
        if (sprite = @sprites.delete(id))
          sprite.dispose unless sprite.disposed?
        end
        next
      end
      sprite = @sprites[id]
      unless sprite
        character = AnilCoopRemoteCharacter.new($game_map)
        character.through = true
        character.character_name = pos["sprite"]
        character.moveto(pos["x"], pos["y"])
        sprite = Sprite_Character.new(Spriteset_Map.viewport, character)
        @sprites[id] = sprite
        log("peer visible slot=#{peer["slot"]} map=#{@map}")
      end
      character = sprite.character
      character.character_name = pos["sprite"]
      character.moveto(pos["x"], pos["y"]) if character.x != pos["x"] || character.y != pos["y"]
      character.direction = pos["direction"]
      character.pattern = pos["pattern"]
      sprite.update
    end
  rescue StandardError => e
    now = Time.now.to_f
    if !@last_error_time || now - @last_error_time > 5
      log("tick error #{e.class}: #{e.message}")
      @last_error_time = now
    end
    clear_sprites
  end
end

class Scene_Map
  alias_method :anil_coop_base_updateSpritesets, :updateSpritesets
  def updateSpritesets(refresh = false)
    anil_coop_base_updateSpritesets(refresh)
    AnilCoop.tick(self)
  end

  alias_method :anil_coop_base_disposeSpritesets, :disposeSpritesets
  def disposeSpritesets
    AnilCoop.clear_sprites
    anil_coop_base_disposeSpritesets
  end

  alias_method :anil_coop_base_update, :update
  def update
    anil_coop_base_update
    AnilCoop.qa_provision
    AnilCoop.qa_trainer
    AnilCoop.qa_wild if AnilCoop.qa_wild_ready?
  end
end

class Battle::Scene
  alias_method :anil_coop_base_pbUpdate, :pbUpdate
  def pbUpdate(cw = nil)
    anil_coop_base_pbUpdate(cw)
    AnilCoop.battle_tick
    AnilCoop.check_battle_transport! if AnilCoop.respond_to?(:check_battle_transport!)
  end
end

class << TrainerBattle
  alias_method :anil_coop_base_start, :start
  def start(*args)
    return anil_coop_base_start(*args) unless ENV["ANIL_COOP_SESSION"] && AnilCoop.connected?
    return anil_coop_base_start(*args) unless pbMapInterpreterRunning?
    event = pbMapInterpreter.get_self
    return anil_coop_base_start(*args) unless event && event.name[/trainer\(\d+\)/i]
    AnilCoop.trainer_lobby(event, event.trigger == 2, args) { anil_coop_base_start(*args) }
  end
end
