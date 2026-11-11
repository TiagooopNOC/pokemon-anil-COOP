# Presence prototype: only trainer coordinates cross the network; wild battles stay local.
require "socket"
require "json"

class AnilCoopRemoteCharacter < Game_Character
  def name; ""; end

  # Only the sprite moves; Game_Character#update would run local map step hooks.
  def follow_network(pos, now = System.uptime, advance: true)
    @remote_steps ||= []
    packet_id = pos.key?("seq") ? pos["seq"] : pos.object_id
    if packet_id != @remote_packet_id
      @remote_packet_id = packet_id
      @remote_direction, @remote_pattern = pos["direction"], pos["pattern"]
      self.move_speed = pos["speed"] if pos["speed"] && pos["speed"] != move_speed
      if !@remote_initialized || pos["warp"] || @remote_map != pos["map"]
        snap_remote(pos["x"], pos["y"])
        @remote_map = pos["map"]
      else
        steps = pos["steps"]
        if steps.is_a?(Array)
          target = @remote_steps.reduce([@x, @y]) { |point, dir| remote_endpoint(*point, dir) }
          target = steps.reduce(target) { |point, dir| remote_endpoint(*point, dir) }
          if target == [pos["x"], pos["y"]] && @remote_steps.length + steps.length <= 32
            @remote_steps.concat(steps)
          else
            AnilCoop.log("remote resync sprite=#{character_name} at=#{[@x, @y].inspect} " \
                         "expected=#{target.inspect} packet=#{[pos['x'], pos['y']].inspect} " \
                         "pending=#{@remote_steps.length} incoming=#{steps.length}")
            snap_remote(pos["x"], pos["y"])
          end
        else
          # Older servers omit steps. Only one cardinal tile is unambiguous.
          target = @remote_steps.reduce([@x, @y]) { |point, dir| remote_endpoint(*point, dir) }
          dx, dy = pos["x"] - target[0], pos["y"] - target[1]
          dir = dx == 1 && dy == 0 ? 6 : dx == -1 && dy == 0 ? 4 :
                dx == 0 && dy == 1 ? 2 : dx == 0 && dy == -1 ? 8 : nil
          if dx != 0 || dy != 0
            dir ? @remote_steps << dir : snap_remote(pos["x"], pos["y"])
          end
        end
      end
    end
    return unless advance
    if @remote_start
      fraction = [[(now - @remote_start) / @remote_duration, 0.0].max, 1.0].min
      @real_x = @remote_from_x + ((@x * Game_Map::REAL_RES_X) - @remote_from_x) * fraction
      @real_y = @remote_from_y + ((@y * Game_Map::REAL_RES_Y) - @remote_from_y) * fraction
      if fraction >= 1.0
        @remote_next_start = @remote_start + @remote_duration
        @remote_start = nil
      end
    end
    if !@remote_start && !@remote_steps.empty?
      dir = @remote_steps.shift
      @remote_from_x, @remote_from_y = @real_x, @real_y
      @x, @y = remote_endpoint(@x, @y, dir)
      self.direction = dir
      @remote_duration = move_speed == 6 ? 0.05 : (move_speed == 5 ? 0.1 : 2.0 / (2**move_speed))
      @remote_start = @remote_next_start || now
      @remote_next_start = nil
      @remote_animation_start = @remote_start
      @remote_animation_pattern = pattern
    end
    @remote_next_start = nil if !@remote_start && @remote_steps.empty?
    if @remote_start
      frame_time = pattern_update_speed / 4.0
      self.pattern = (@remote_animation_pattern + ((now - @remote_animation_start) / frame_time).floor) % 4
    elsif @remote_steps.empty?
      self.direction = @remote_direction
      self.pattern = @remote_pattern
    end
  end

  def remote_endpoint(x, y, dir)
    case dir
    when 2 then [x, y + 1]
    when 4 then [x - 1, y]
    when 6 then [x + 1, y]
    when 8 then [x, y - 1]
    else [x, y]
    end
  end

  def snap_remote(x, y)
    @x, @y = x, y
    @real_x, @real_y = x * Game_Map::REAL_RES_X, y * Game_Map::REAL_RES_Y
    @remote_steps.clear
    @remote_start = nil
    @remote_next_start = nil
    @remote_initialized = true
  end
end

module AnilCoopPlayerSteps
  def move_generic(dir, turn_enabled = true)
    old_x, old_y = @x, @y
    super
    AnilCoop.record_step(dir) if (@x - old_x).abs + (@y - old_y).abs == 1
  end
end
Game_Player.prepend(AnilCoopPlayerSteps)

if defined?(Game_FollowingPkmn)
  module AnilCoopFollowerSteps
    def move_generic(dir, turn_enabled = true)
      old_x, old_y = @x, @y
      super
      if (@x - old_x).abs + (@y - old_y).abs == 1
        AnilCoop.record_follower_step(self, dir)
      end
    end
  end
  Game_FollowingPkmn.prepend(AnilCoopFollowerSteps)
end

module AnilCoop
  @peers = {}
  @position_queue = {}
  @sprites = {}
  @labels = {}
  @follower_sprites = {}
  @trainer_states = {}
  @sequence = 0
  @buffer = +""
  @out = +""
  @last_send = 0.0
  @last_ping = 0.0
  @last_connect = 0.0
  @map = nil

  def self.record_step(dir)
    return unless connected? && [2, 4, 6, 8].include?(dir)
    @pending_steps ||= []
    if @pending_steps.length < 24
      @pending_steps << dir
    else
      @steps_overflow = true
    end
  end

  def self.position_steps(map, x, y)
    steps = @pending_steps || []
    previous = @last_sent_position
    endpoint = previous && previous[0] == map ? previous[1, 2] : nil
    steps.each do |dir|
      break unless endpoint
      endpoint = [endpoint[0] + (dir == 6 ? 1 : dir == 4 ? -1 : 0),
                  endpoint[1] + (dir == 2 ? 1 : dir == 8 ? -1 : 0)]
    end
    warp = @steps_overflow || endpoint != [x, y]
    @pending_steps = []
    @steps_overflow = false
    @last_sent_position = [map, x, y]
    [warp ? [] : steps, !!warp]
  end

  def self.record_follower_step(event, dir)
    return unless connected? && [2, 4, 6, 8].include?(dir)
    return unless @follower_event.equal?(event)
    @pending_follower_steps ||= []
    if @pending_follower_steps.length < 24
      @pending_follower_steps << dir
    else
      @follower_steps_overflow = true
    end
  end

  def self.follower_position(sequence)
    unless defined?(FollowingPkmn) && FollowingPkmn.can_check? && FollowingPkmn.active?
      @follower_event = nil
      @last_sent_follower = nil
      @pending_follower_steps = []
      return nil
    end
    event = FollowingPkmn.get_event
    unless event && event.map.map_id == $game_map.map_id &&
           !event.transparent &&
           event.character_name.to_s.match?(/\AFollowers(?: shiny)?\/[[:alnum:]_ -]{1,80}\.png\z/) &&
           event.x.between?(0, 9999) && event.y.between?(0, 9999) &&
           [2, 4, 6, 8].include?(event.direction) && event.pattern.between?(0, 3) &&
           event.move_speed.between?(1, 8) &&
           event.character_hue.is_a?(Integer) && event.character_hue.between?(0, 360)
      @follower_event = nil
      @last_sent_follower = nil
      @pending_follower_steps = []
      return nil
    end
    map = event.map.map_id
    steps = @pending_follower_steps || []
    previous = @last_sent_follower
    endpoint = previous && previous[0] == map && @follower_event.equal?(event) ? previous[1, 2] : nil
    steps.each do |dir|
      break unless endpoint
      endpoint = [endpoint[0] + (dir == 6 ? 1 : dir == 4 ? -1 : 0),
                  endpoint[1] + (dir == 2 ? 1 : dir == 8 ? -1 : 0)]
    end
    warp = @follower_steps_overflow || endpoint != [event.x, event.y]
    @follower_event = event
    @last_sent_follower = [map, event.x, event.y]
    @pending_follower_steps = []
    @follower_steps_overflow = false
    { map: map, x: event.x, y: event.y, direction: event.direction,
      pattern: event.pattern, speed: event.move_speed, sprite: event.character_name,
      hue: event.character_hue, seq: sequence, steps: warp ? [] : steps, warp: !!warp }
  end

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
    Compiler.push_script(page.list, 'if TrainerBattle.start(:AZUL1, "Azul", 1); $game_self_switches[[$game_map.map_id, 9000, "A"]] = true; $game_map.need_refresh = true; end')
    Compiler.push_end(page.list)
    defeated = RPG::Event::Page.new
    defeated.condition.self_switch_valid = true
    defeated.condition.self_switch_ch = "A"
    defeated.graphic = Marshal.load(Marshal.dump(page.graphic))
    Compiler.push_script(defeated.list, 'pbMessage("Ya hemos combatido.")')
    Compiler.push_end(defeated.list)
    event.pages << defeated
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
      $PokemonGlobal.challenge_encs = {}
      ChallengeModes.begin_challenge
    end
    saved = Game.save("Partida 1")
    log("qa provision species=#{$player.party[0]&.species} random=#{RandomizedChallenge.enabled?} locke=#{ChallengeModes.on?} saved=#{saved}")
  rescue StandardError => e
    log("qa provision error #{e.class}: #{e.message}")
  end

  def self.disconnect
    online_invite_disconnect if respond_to?(:online_invite_disconnect)
    speed_disconnect if respond_to?(:speed_disconnect)
    @battle_failure = "connection lost" if @active_battle
    @socket&.close rescue nil
    @socket = nil
    @id = nil
    @peers.clear
    @position_queue.clear
    @pending_steps = []
    @last_sent_position = nil
    @steps_overflow = false
    @follower_event = nil
    @last_sent_follower = nil
    @pending_follower_steps = []
    @follower_steps_overflow = false
    @trainer_states.clear
    clear_sprites
    log("disconnected")
  end

  def self.clear_sprites
    @sprites.each_value { |s| s.dispose unless s.disposed? }
    @sprites.clear
    @labels.each_value { |entry| entry[:sprite].dispose unless entry[:sprite].disposed? }
    @labels.clear
    @follower_sprites.each_value { |s| s.dispose unless s.disposed? }
    @follower_sprites.clear
  end

  def self.remove_follower_sprite(id)
    sprite = @follower_sprites.delete(id)
    sprite.dispose if sprite && !sprite.disposed?
  end

  def self.update_follower_sprite(id, position, advance: true)
    unless position.is_a?(Hash) && position["map"] == @map && !position["sprite"].to_s.empty?
      remove_follower_sprite(id)
      return
    end
    sprite = @follower_sprites[id]
    unless sprite
      character = AnilCoopRemoteCharacter.new($game_map)
      character.through = true
      character.character_name = position["sprite"]
      character.character_hue = position["hue"]
      character.follow_network(position, advance: false)
      sprite = Sprite_Character.new(Spriteset_Map.viewport, character)
      @follower_sprites[id] = sprite
    end
    character = sprite.character
    character.character_name = position["sprite"]
    character.character_hue = position["hue"]
    character.follow_network(position, advance: advance)
    sprite.update
  end

  def self.remove_label(id)
    entry = @labels.delete(id)
    entry[:sprite].dispose if entry && !entry[:sprite].disposed?
  end

  def self.update_label(id, name, character_sprite)
    name = name.to_s[0, 12]
    if name.empty? || !character_sprite.visible || !character_sprite.bitmap
      remove_label(id)
      return
    end
    entry = @labels[id]
    if !entry || entry[:name] != name
      remove_label(id)
      label = BitmapSprite.new(104, 19, Spriteset_Map.viewport)
      bitmap = label.bitmap
      pbSetSmallFont(bitmap)
      width = [[bitmap.text_size(name).width + 10, 24].max, 100].min
      bitmap.fill_rect((104 - width) / 2, 1, width, 17, Color.new(16, 24, 40, 145))
      pbDrawTextPositions(bitmap, [[name, 52, -2, :center,
                                    Color.new(248, 248, 248), Color.new(40, 40, 40)]])
      entry = { name: name, sprite: label }
      @labels[id] = entry
    end
    label = entry[:sprite]
    label.x = character_sprite.x - label.bitmap.width / 2
    label.y = character_sprite.y - character_sprite.oy * character_sprite.zoom_y - label.bitmap.height - 3
    label.z = character_sprite.z + 20
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
      speed_receive(message) if respond_to?(:speed_receive)
      speed_welcome if respond_to?(:speed_welcome)
    when "enter", "position"
      p = message["player"]
      @peers[p["id"]] = p if p.is_a?(Hash) && p["id"].is_a?(String) && p["id"] != @id
      if message["type"] == "position" && p.is_a?(Hash) && p["id"].is_a?(String) &&
         p["position"].is_a?(Hash) && p["id"] != @id
        packets = (@position_queue[p["id"]] ||= [])
        packets << p["position"]
        if packets.length > 32
          latest = p["position"].merge("warp" => true, "steps" => [], "follower" => nil)
          packets.replace([latest])
          log("remote packet queue overflow; resync slot=#{p['slot']}")
        end
      end
      log("peer #{message["type"]} slot=#{p["slot"]}") if p.is_a?(Hash) && message["type"] == "enter"
      speed_receive(message) if message["type"] == "enter" && respond_to?(:speed_receive)
    when "leave"
      @peers.delete(message["id"])
      @position_queue.delete(message["id"])
      if (sprite = @sprites.delete(message["id"]))
        sprite.dispose unless sprite.disposed?
      end
      remove_label(message["id"])
      remove_follower_sprite(message["id"])
      log("peer left #{message["id"]}")
      speed_receive(message) if respond_to?(:speed_receive)
    when "speed_state"
      speed_receive(message) if respond_to?(:speed_receive)
    when "team_view_query", "team_view_data", "team_view_error"
      online_team_receive(message) if respond_to?(:online_team_receive)
    when "invite_offer", "invite_state"
      online_invite_receive(message) if respond_to?(:online_invite_receive)
    when "trainer_state"
      @trainer_states[[message["map"], message["event"]]] = message
      log("trainer state map=#{message["map"]} event=#{message["event"]} phase=#{message["phase"]} players=#{message["participants"].length}")
    when "trainer_closed"
      @trainer_states.delete([message["map"], message["event"]])
    when "battle_step", "battle_abort"
      battle_receive(message) if respond_to?(:battle_receive)
    when "pong"
      battle_wait_status(message) if respond_to?(:battle_wait_status)
    when "error"
      @connection_error = message["reason"]
      log("server error #{message["reason"]}")
      if message["reason"].to_s.start_with?("battle_")
        @battle_failure = message["reason"] if @active_battle
      elsif message["reason"].to_s.start_with?("speed_") || message["reason"] == "invalid_speed"
        log("speed request rejected #{message['reason']}")
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
    return unless ENV["ANIL_COOP_SESSION"]
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
      mine = state && state["participants"].any? { |p| p["id"] == @id }
      return state if state && (!phase || state["phase"] == phase) && (phase != "pending" || mine)
      return nil if !@socket || @trainer_error || Time.now.to_f >= deadline
    end
  end

  def self.start_qa_battle(state)
    # Development fixture only: reload between attempts, never during a battle.
    load "CoopDev/coop_battle.rb" if qa_2v2?
    qa_coop_battle(state)
  end

  # Native windows and normal input; automatically leave the menu when the host starts.
  def self.trainer_choice(key, text, commands)
    status = Window_AdvancedTextPokemon.new(text)
    status.width = Graphics.width
    status.height = 112
    status.z = 99998
    menu = Window_CommandPokemon.new(commands)
    menu.width = Graphics.width
    menu.height = Graphics.height - status.height
    menu.y = status.height
    menu.z = 99999
    menu.index = [@trainer_menu_index || 0, commands.length - 1].min
    before = @trainer_states[key]
    loop do
      Graphics.update
      Input.update
      status.update
      menu.update
      tick($scene)
      return :refresh unless @trainer_states[key].equal?(before)
      if block_given?
        programmed = yield
        return programmed unless programmed.nil?
      end
      if Input.trigger?(Input::USE)
        @trainer_menu_index = menu.index
        return menu.index
      end
      return -1 if Input.trigger?(Input::BACK)
    end
  ensure
    menu&.dispose
    status&.dispose
  end

  def self.trainer_lobby(event, forced, trainer_args = nil, story: false)
    key = [event.map_id, event.id]
    @trainer_states.delete(key)
    @trainer_error = nil
    @pending_foe = nil
    extras = { forced: forced }
    extras[:prototype] = battle_prototype if respond_to?(:qa_2v2?) && qa_2v2? && (personal_team? || event.id == 9000)
    if personal_team? && trainer_args
      extras[:encounter_key] = trainer_identity(event, trainer_args)
      if !story && trainer_completed?(extras[:encounter_key])
        pbMessage("Ya derrotaste a este entrenador en tu partida.") { network }
        return false
      end
    end
    trainer_send("trainer_wait", event, extras)
    state = trainer_wait_for(event, "pending")
    if !state && forced
      log("trainer fallback #{trainer_call_label(event, trainer_args || [])} reason=#{@trainer_error || 'lobby_timeout'}")
      if @trainer_error == "trainer_incompatible"
        pbMessage("Este entrenador tiene una variante distinta para cada jugador.\nSe iniciará el combate individual.") { network }
      end
      return yield
    end
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
      choice = trainer_choice(key, "Entrenador en espera.\n#{lines.join(" / ")}", commands)
      next if choice == :refresh
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
            log("trainer fallback #{trainer_call_label(event, trainer_args)} reason=foe_unsupported:#{e.class}")
            pbMessage("Cooperativo no disponible: #{e.message}\nSe iniciará el combate individual.") { network }
            solo = true
          end
        end
        trainer_send("trainer_start", event, solo: solo)
        locked = trainer_wait_for(event, "locked")
        if locked && locked["participants"].any? { |p| p["id"] == @id }
          return start_qa_battle(locked) if locked["battle"]
          log("trainer solo start map=#{event.map_id} event=#{event.id}")
          begin
            won = yield
            if won && extras[:encounter_key] && !story
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
        steps, warp = position_steps($game_map.map_id, $game_player.x, $game_player.y)
        queue(type: "position", map: $game_map.map_id, x: $game_player.x,
              y: $game_player.y, direction: $game_player.direction,
              pattern: $game_player.pattern, speed: $game_player.move_speed,
              sprite: sprite_name, seq: @sequence, steps: steps, warp: warp,
              follower: follower_position(@sequence))
      end
    end
    if @map != $game_map.map_id
      clear_sprites
      @map = $game_map.map_id
    end
    @peers.each do |id, peer|
      pos = peer["position"]
      positions = @position_queue.delete(id) || []
      positions.select! { |entry| entry["map"] == @map }
      positions = [pos] if positions.empty?
      if !pos.is_a?(Hash) || pos["map"] != @map || pos["sprite"].to_s.empty?
        if (sprite = @sprites.delete(id))
          sprite.dispose unless sprite.disposed?
        end
        remove_label(id)
        remove_follower_sprite(id)
        next
      end
      sprite = @sprites[id]
      unless sprite
        character = AnilCoopRemoteCharacter.new($game_map)
        character.through = true
        character.character_name = positions.first["sprite"]
        character.follow_network(positions.first, advance: false)
        sprite = Sprite_Character.new(Spriteset_Map.viewport, character)
        @sprites[id] = sprite
        log("peer visible slot=#{peer["slot"]} map=#{@map}")
      end
      character = sprite.character
      character.character_name = pos["sprite"]
      positions.each { |entry| character.follow_network(entry, advance: false) }
      character.follow_network(pos)
      sprite.update
      update_label(id, peer["name"], sprite)
      positions.each { |entry| update_follower_sprite(id, entry["follower"], advance: false) }
      update_follower_sprite(id, pos["follower"])
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
    context = AnilCoop.story_script_context
    event = context && context[:interpreter].get_self
    event ||= pbMapInterpreter.get_self if pbMapInterpreterRunning?
    label = AnilCoop.trainer_call_label(event, args)
    if !ENV["ANIL_COOP_SESSION"]
      AnilCoop.log("trainer fallback #{label} reason=no_session") if ENV["ANIL_COOP_MENU"] == "1"
      return anil_coop_base_start(*args)
    end
    unless AnilCoop.connected?
      deadline = Time.now.to_f + 2
      until AnilCoop.connected? || Time.now.to_f >= deadline
        AnilCoop.tick($scene)
        Graphics.update
      end
    end
    unless AnilCoop.connected?
      AnilCoop.log("trainer fallback #{label} reason=transport_disconnected")
      return anil_coop_base_start(*args)
    end
    unless event
      AnilCoop.log("trainer fallback #{label} reason=event_missing")
      return anil_coop_base_start(*args)
    end
    ordinary = !!event.name[/trainer\(\d+\)/i]
    reason = ordinary ? nil : AnilCoop.story_trainer_compatible?(event, args)
    if reason
      AnilCoop.log("trainer fallback #{label} reason=#{reason}")
      pbMessage("Este encuentro especial requiere combate individual.") if reason.start_with?("unsupported_rules")
      return anil_coop_base_start(*args)
    end
    story = !ordinary
    AnilCoop.log("trainer adapter #{label} kind=#{story ? 'story' : 'ordinary'}")
    AnilCoop.instance_variable_set(:@story_battle, story)
    AnilCoop.trainer_lobby(event, story || event.trigger == 2, args, story: story) { anil_coop_base_start(*args) }
  ensure
    AnilCoop.instance_variable_set(:@story_battle, false)
  end
end
