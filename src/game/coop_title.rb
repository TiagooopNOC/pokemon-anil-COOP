# Add the multiplayer entry to Añil's existing load screen without replacing it.
module AnilCoop
  MENU_ERRORS = {
    "auth_failed" => "Código de sala incorrecto.",
    "no_session" => "La IP responde, pero esa sala no está abierta allí. Comprobá IP y código con el anfitrión.",
    "session_exists" => "La sala ya está abierta.",
    "session_full" => "La sala está llena."
  }.freeze

  def self.menu_request(operation, values = {})
    socket = Socket.tcp("127.0.0.1", Integer(ENV.fetch("ANIL_COOP_CONTROL_PORT")), connect_timeout: 2)
    socket.write(JSON.generate({ op: operation, token: ENV.fetch("ANIL_COOP_CONTROL_TOKEN") }.merge(values)) + "\n")
    ready = IO.select([socket], nil, nil, 7)
    raise "El auxiliar de conexión no responde." unless ready
    result = JSON.parse(socket.gets || "")
    raise(result["error"] || "Error del auxiliar") unless result["ok"]
    result
  rescue Errno::ECONNREFUSED, EOFError, JSON::ParserError
    raise "No se encuentra el auxiliar local. Reiniciá el lanzador."
  ensure
    socket&.close
  end

  def self.menu_stop
    ENV.delete("ANIL_COOP_SESSION")
    ENV.delete("ANIL_COOP_PORT")
    ENV.delete("ANIL_COOP_MODE")
    disconnect
    @resume = nil
    menu_request("stop")
  end

  def self.valid_multiplayer_name?(value)
    value.is_a?(String) && !!value.match(/\A[A-Za-z0-9_]{3,12}\z/)
  end

  def self.prompt_multiplayer_name
    initial = ENV["ANIL_COOP_NAME"] || ""
    loop do
      name = pbEnterText("Nombre multijugador (3–12, sin espacios)", 0, 12, initial)
      return nil if name.to_s.empty?
      return name if valid_multiplayer_name?(name)
      pbMessage("Usá de 3 a 12 letras, números o guion bajo; sin espacios.")
      initial = name
    end
  end

  def self.menu_start(mode, host, code = nil, name: nil)
    player_name = name || ENV["ANIL_COOP_NAME"] || File.basename(File.dirname(AnilCoopDev::PROFILE))
    raise "Nombre multijugador inválido (3–12 letras, números o _)." unless valid_multiplayer_name?(player_name)
    data = menu_request(mode, { host: host, code: code })
    disconnect
    @resume = nil
    @connection_error = nil
    @last_connect = 0
    ENV["ANIL_COOP_SESSION"] = data.fetch("code")
    ENV["ANIL_COOP_PORT"] = data.fetch("port").to_s
    ENV["ANIL_COOP_MODE"] = mode
    ENV["ANIL_COOP_NAME"] = player_name
    deadline = Time.now.to_f + 8
    until connected? || Time.now.to_f >= deadline || @connection_error
      Graphics.update
      Input.update
      connect
      network
    end
    return data if connected?
    reason = MENU_ERRORS.fetch(@connection_error, @connection_error.to_s)
    begin
      menu_stop
    rescue StandardError => e
      log("menu cleanup #{e.class}: #{e.message}")
    end
    raise(reason.empty? ? "No se pudo conectar. Revisá la IP, sala y firewall." : reason)
  end

  def self.invitation(host, code)
    "#{host} #{code}"
  end

  def self.parse_invitation(value)
    parts = value.to_s.strip.split(/\s+/)
    raise "Copiá la invitación completa (IP y código)." unless
      parts.length == 2 && parts[0].match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/) &&
      parts[1].match?(/\A[A-Za-z0-9]{12}\z/)
    [parts[0], parts[1].upcase]
  end

  def self.copy_room_data(session)
    labels = ["Copiar invitación", "Copiar IP", "Copiar código", "Volver"]
    choice = pbMessage("Datos de la sala", labels, -1)
    return if choice == 3 || choice == -1
    value = [invitation(session["host"], session["code"]), session["host"], session["code"]][choice]
    Input.clipboard = value
    pbMessage("Copiado al portapapeles.")
  rescue StandardError
    pbMessage("No se pudo usar el portapapeles en este equipo.")
  end

  def self.confirm_online_disconnect
    pbMessage("¿Querés desconectarte de la sala?", ["Sí", "No"], -1, nil, 1) { battle_tick } == 0
  end

  def self.multiplayer_menu
    loop do
      status = menu_request("status")
      session = status["session"]
      if session
        battle_tick
        peers = @peers.values.map { |p| p["name"] }.join(", ")
        text = "Sala #{session['code']} | #{session['host']}\n" \
               "Estado: #{connected? ? 'conectado' : 'sin conexión'} | " \
               "Jugadores: #{1 + @peers.length}#{peers.empty? ? '' : " (#{peers})"}"
        choice = pbMessage(text, ["Cargar partida", "Copiar datos", "Reintentar", "Desconectar", "Volver"], -1) { battle_tick }
        case choice
        when 0, 4, -1 then return
        when 1 then copy_room_data(session)
        when 2
          begin
            menu_stop
            menu_start(session["mode"], session["host"], session["code"])
          rescue StandardError => e
            pbMessage(e.message)
          end
        when 3 then menu_stop if confirm_online_disconnect
        end
      else
        choice = pbMessage("Conectate antes de cargar tu partida.",
                           ["Crear partida", "Unirse a un amigo", "Pegar invitación", "Volver"], -1)
        return if choice == 3 || choice == -1
        begin
          if choice == 0
            name = prompt_multiplayer_name
            next unless name
            addresses = status["addresses"] || []
            host = pbEnterText("Tu IP LAN/Tailscale/Hamachi", 7, 15, addresses[0] || "")
            next if host.to_s.empty?
            data = menu_start("create", host, nil, name: name)
            pbMessage("Sala creada: #{data['code']}\nIP: #{host}\n" \
                      "Compartí estos dos datos con tu amigo.") { battle_tick }
          elsif choice == 1
            name = prompt_multiplayer_name
            next unless name
            host = pbEnterText("IP privada de tu amigo", 7, 15)
            next if host.to_s.empty?
            code = pbEnterText("Código de sala", 12, 12).upcase
            next if code.empty?
            menu_start("join", host, code, name: name)
            pbMessage("Conectado. Ya podés cargar tu partida.") { battle_tick }
          elsif choice == 2
            name = prompt_multiplayer_name
            next unless name
            host, code = parse_invitation(Input.clipboard)
            menu_start("join", host, code, name: name)
            pbMessage("Conectado. Ya podés cargar tu partida.") { battle_tick }
          end
        rescue StandardError => e
          pbMessage("Conexión: #{e.message}")
        end
      end
    end
  rescue StandardError => e
    pbMessage("Multijugador: #{e.message}")
  end
end

module AnilCoopTitleMenu
  def pbStartScene(commands, *args)
    commands.insert(commands.length - 1, "Multijugador") if
      ENV["ANIL_COOP_MENU"] == "1" && !commands.include?("Multijugador")
    super
  end

  # Multi Save passes its Continue index as a second argument. Forward it so
  # Left/Right save-slot selection keeps working on the original title screen.
  def pbChoose(commands, *args)
    loop do
      index = super(commands, *args)
      multiplayer = commands.index("Multijugador")
      if index == multiplayer
        AnilCoop.multiplayer_menu
      else
        return multiplayer && index > multiplayer ? index - 1 : index
      end
    end
  end

  def pbUpdate
    super
    AnilCoop.battle_tick if ENV["ANIL_COOP_SESSION"]
  end
end

PokemonLoad_Scene.prepend(AnilCoopTitleMenu)

# Multi Save stores the old manual slot inside Player. An imported file may
# have been placed in a different slot to preserve an existing Co-op save.
module AnilCoopManualSaveSlot
  def load_save_file(file_path)
    data = super
    slot = File.basename(file_path, ".rxdata")
    if slot.match?(/\APartida [0-9]+\z/) && data.is_a?(Hash) && data[:player]
      data[:player].save_slot = slot
    end
    data
  end
end

PokemonLoadScreen.prepend(AnilCoopManualSaveSlot)
