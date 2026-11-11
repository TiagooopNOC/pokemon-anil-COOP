# The installed Añil uses DP_PauseMenu for ESC. Keep its scene and navigation.
module AnilCoop
  def self.online_available?
    return false unless $scene.is_a?(Scene_Map) && $game_map && $game_temp
    return false if $game_temp.in_battle || coop_battle_active?
    return false if $game_map.respond_to?(:interpreter) && $game_map.interpreter&.running?
    true
  end

  def self.online_menu
    unless online_available?
      pbMessage("Online no está disponible durante eventos, transiciones o combates.")
      return
    end
    unless ENV["ANIL_COOP_CONTROL_PORT"] && ENV["ANIL_COOP_CONTROL_TOKEN"]
      pbMessage("Para usar Online, abrí Pokémon Añil desde el lanzador Co-op.")
      return
    end
    AnilCoopOnlineScreen.new.run
  rescue StandardError => e
    pbMessage("Online: #{e.message}")
  end

  def self.online_connect_choice(choice, status)
    return unless online_available?
    name = prompt_multiplayer_name
    return unless name
    case choice
    when 0
      host = pbEnterText("Tu IP LAN/Tailscale/Hamachi", 7, 15, Array(status["addresses"])[0] || "")
      return if host.to_s.empty?
      data = menu_start("create", host, nil, name: name)
      pbMessage("Sala #{data['code']} creada. Compartí la IP y el código.") { tick($scene) }
    when 1
      host = pbEnterText("IP privada de tu amigo", 7, 15)
      return if host.to_s.empty?
      code = pbEnterText("Código de sala", 12, 12).upcase
      return if code.empty?
      menu_start("join", host, code, name: name)
    when 2
      host, code = parse_invitation(Input.clipboard)
      menu_start("join", host, code, name: name)
    end
  end

  def self.online_players
    loop do
      if @peers.empty?
        pbMessage("Conectado al servidor. No hay otros jugadores en la sala.")
        return
      end
      peers = @peers.values
      names = peers.map do |peer|
        map = peer.dig("position", "map")
        zone = map && GameData::MapMetadata.exists?(map) ? GameData::MapMetadata.get(map).name : "Ubicación no disponible"
        "#{peer['name']} — conectado — #{zone}"
      end
      choice = pbMessage("Jugadores conectados", names + ["Volver"], -1) { tick($scene) }
      return if choice < 0 || choice >= peers.length
      online_peer_menu(peers[choice]["id"])
    end
  end

  def self.online_peer_menu(peer_id)
    loop do
      peer = @peers[peer_id]
      unless peer
        pbMessage("El compañero se desconectó.")
        return
      end
      trade_request = online_invite_pending(peer_id, "trade")
      pvp_request = online_invite_pending(peer_id, "pvp")
      options = ["Ver equipo", "Ver ubicación",
                 trade_request ? "Cancelar solicitud de intercambio" : "Solicitar intercambio",
                 pvp_request ? "Cancelar desafío" : "Desafiar a combate", "Volver"]
      choice = pbMessage(peer["name"], options, -1) { tick($scene) }
      return if choice < 0 || choice == 4
      unless @peers.key?(peer_id)
        pbMessage("El compañero se desconectó.")
        return
      end
      case choice
      when 0 then online_view_team(peer_id)
      when 1 then online_locations(peer_id)
      when 2, 3
        kind = choice == 2 ? "trade" : "pvp"
        pending = choice == 2 ? trade_request : pvp_request
        begin
          pending ? online_invite_cancel(pending) : online_invite_send(peer_id, kind)
        rescue StandardError => e
          pbMessage("Invitación: #{e.message}")
        end
      end
    end
  end
end

module AnilCoopDPPauseMenu
  def main
    unless @options.any? { |entry| entry[0] == "Online" }
      exit_index = @options.index { |entry| entry[0] == "Salir" } || @options.length
      @options.insert(exit_index, ["Online", "controlesA", "controlesB", proc {
        @sprites.visible = false
        begin
          AnilCoop.online_menu
        ensure
          @sprites.visible = true unless @done
        end
      }])
      @count = @options.length
      @viewport.rect.height = 24 + 48 * @count
      @viewport.rect.y = -12 if @count >= 8
      if @count >= 8 && @sprites[:helpful_text_txt]
        # The native F1 hint sits under the eighth row. Keep the level-cap
        # information on the left and leave the original menu navigation free.
        @sprites[:helpful_text_txt].clear
        @sprites[:helpful_text_txt].draw([_INTL("Nivel máx. actual: {1}", LevelCapsEX.level_cap),
                                          24, Graphics.height - 45, 0,
                                          DP_PauseMenu::BaseColor, DP_PauseMenu::ShadowColor])
        if defined?(ChallengeModes) && ChallengeModes.on?(:MODOVIDAS) &&
           $PokemonGlobal.challenge_lives && $PokemonGlobal.challenge_lives >= 0
          @sprites[:helpful_text_txt].draw([_INTL("Vidas: {1}", $PokemonGlobal.challenge_lives),
                                            24, Graphics.height - 15, 0,
                                            DP_PauseMenu::BaseColor, DP_PauseMenu::ShadowColor])
        end
      end
      @sprites[:bgMid].zoom_y = 48 * @count
      @sprites[:bgBtm].y = 12 + @sprites[:bgMid].zoom_y
      @sprites[:txt].clear
      @options.each_with_index do |entry, index|
        @sprites[:txt].draw([entry[0], 72, 26 + 48 * index, 0,
                             DP_PauseMenu::BaseColor, DP_PauseMenu::ShadowColor])
        icon = @sprites[entry[0].to_sym]
        unless icon
          icon = Sprite.new(@viewport)
          @sprites[entry[0].to_sym] = icon
        end
        path = entry[index == @option ? 2 : 1]
        path = path[$player.gender] if path.is_a?(Array)
        icon.bmp("Graphics/Pictures/DP Pause Menu/#{path}")
        icon.center_origins
        icon.xyz = 39, 36 + 48 * index
      end
    end
    super
  end

end

DP_PauseMenu.prepend(AnilCoopDPPauseMenu) if defined?(DP_PauseMenu)
