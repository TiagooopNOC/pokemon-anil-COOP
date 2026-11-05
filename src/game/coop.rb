# Presence prototype: only trainer coordinates cross the network; wild battles stay local.
require "socket"
require "json"

class AnilCoopRemoteCharacter < Game_Character
  def name; ""; end
end

module AnilCoop
  @peers = {}
  @sprites = {}
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

  def self.disconnect
    @socket&.close rescue nil
    @socket = nil
    @id = nil
    @peers.clear
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
    when "error"
      log("server error #{message["reason"]}")
      disconnect
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
      raise "oversize network message" if @buffer.bytesize > 16384
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
    log("qa wild begin")
    result = WildBattle.start(:RATTATA, 3)
    log("qa wild end result=#{result}")
  rescue StandardError => e
    log("qa wild error #{e.class}: #{e.message}")
  ensure
    $player.party.delete(temporary_pokemon) if temporary_pokemon
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
    AnilCoop.qa_wild if AnilCoop.qa_wild_ready?
  end
end

class Battle::Scene
  alias_method :anil_coop_base_pbUpdate, :pbUpdate
  def pbUpdate(cw = nil)
    anil_coop_base_pbUpdate(cw)
    AnilCoop.battle_tick
  end
end
