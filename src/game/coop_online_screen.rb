# Native-resolution Online scene. The connection belongs to AnilCoop, not this viewport.
class AnilCoopOnlineScreen
  BASE = Color.new(245, 248, 255)
  MUTED = Color.new(192, 211, 247)
  GOLD = Color.new(255, 222, 118)
  SHADOW = Color.new(22, 38, 88)
  PANEL = Color.new(12, 39, 128, 225)
  ROW = Color.new(27, 66, 165, 230)
  SELECTED = Color.new(83, 131, 222, 245)

  def initialize
    @mode = :main
    @selected_peer = nil
    @selected = 0
    @options = []
    @status = {}
    @last_status = 0
    @last_draw = 0
  end

  def run
    @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
    @viewport.z = 99998
    @sprites = {}
    @sprites["background"] = IconSprite.new(0, 0, @viewport)
    @sprites["background"].setBitmap("Graphics/UI/Town Map/bg")
    @sprites["content"] = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
    AnilCoop.instance_variable_set(:@online_screen_active, true)
    refresh_status(true)
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      break if AnilCoop.pvp_preparing?
      refresh_status
      rebuild_options
      visual = [AnilCoop.connected?, @mode, @selected_peer, @selected,
                @status["session"], ENV["ANIL_COOP_NAME"], $GameSpeed,
                AnilCoop.instance_variable_get(:@peers).values.map do |peer|
                  [peer["id"], peer["name"], peer.dig("position", "map")]
                end, @options.map { |option| option[:label] }]
      if visual != @last_visual || Time.now.to_f - @last_draw > 0.5
        draw
        @last_visual = visual
        @last_draw = Time.now.to_f
      end
      if Input.trigger?(Input::BACK)
        if @mode == :peer
          @mode = :main
          @desired_action = nil
          focus(:peer, @selected_peer)
        else
          pbPlayCancelSE
          break
        end
      elsif Input.repeat?(Input::UP)
        move(-1)
      elsif Input.repeat?(Input::DOWN)
        move(1)
      elsif Input.repeat?(Input::LEFT)
        move_section(-1)
      elsif Input.repeat?(Input::RIGHT)
        move_section(1)
      elsif Input.trigger?(Input::USE)
        option = @options[@selected]
        if option && option[:action] == :back
          if @mode == :peer
            @mode = :main
            @desired_action = nil
            focus(:peer, @selected_peer)
          else
            break
          end
        else
          execute(option) if option
        end
      end
    end
  ensure
    AnilCoop.instance_variable_set(:@online_screen_active, false)
    pbDisposeSpriteHash(@sprites) if @sprites
    @viewport.dispose if @viewport && !@viewport.disposed?
  end

  def refresh_status(force = false)
    now = Time.now.to_f
    return unless force || now - @last_status > 1
    @last_status = now
    @status = AnilCoop.menu_request("status")
    @status_error = nil
  rescue StandardError => e
    @status = {}
    @status_error = e.message
  end

  def add(action, label, group, x, y, width, height, peer = nil)
    @options << { action: action, label: label, group: group,
                  rect: Rect.new(x, y, width, height), peer: peer }
  end

  def rebuild_options
    prior = @options[@selected]
    key = prior && [prior[:action], prior[:peer]]
    @options = []
    peers = AnilCoop.instance_variable_get(:@peers)
    if @mode == :peer && !peers.key?(@selected_peer)
      @mode = :main
      @selected_peer = nil
      @desired_action = nil
    end
    if AnilCoop.connected?
      add(:copy, "Copiar invitación", :room, Graphics.width - 156, 76, 140, 29) if @status["session"]
      peers.values.sort_by { |peer| peer["slot"].to_i }.first(3).each_with_index do |peer, i|
        add(:peer, peer["name"], :peers, 16, 165 + i * 48, 231, 43, peer["id"])
      end
      actions = if @mode == :peer
                  [[:team, "Ver equipo"], [:location, "Ver ubicación"],
                   [:trade, AnilCoop.online_invite_pending(@selected_peer, "trade") ? "Cancelar solicitud" : "Solicitar intercambio"],
                   [:pvp, AnilCoop.online_invite_pending(@selected_peer, "pvp") ? "Cancelar desafío" : "Desafiar a combate"],
                   [:back_peer, "Volver a Online"]]
                else
                  [[:players, "Jugadores conectados"], [:map, "Mapa regional"],
                   [:teams, "Ver equipos"], [:trades, "Intercambios · invitaciones"],
                   [:battles, "Combates PvP · invitaciones"]]
                end
      actions.each_with_index { |entry, i| add(entry[0], entry[1], :actions, 264, 165 + i * 29, 232, 28) }
      add(:disconnect, "Desconectarse", :footer, Graphics.width - 248, Graphics.height - 44, 232, 30)
    else
      [[:create, "Crear sala"], [:join, "Unirse a un amigo"],
       [:paste, "Pegar invitación"]].each_with_index do |entry, i|
        add(entry[0], entry[1], :actions, 32, 174 + i * 37, Graphics.width - 64, 32)
      end
      add(:retry, "Reintentar conexión", :actions, 32, 285, Graphics.width - 64, 32) if @status["session"]
    end
    add(:back, "Volver", :footer, 16, Graphics.height - 44, 231, 30)
    @selected = @options.index { |option| [option[:action], option[:peer]] == key } ||
                [@selected, @options.length - 1].min
    @selected = 0 if @selected < 0
  end

  def focus(action, peer = nil)
    rebuild_options
    @selected = @options.index { |option| option[:action] == action && option[:peer] == peer } || @selected
  end

  def move(delta)
    @selected = (@selected + delta) % @options.length
    pbPlayCursorSE
  end

  def move_section(delta)
    groups = @options.map { |option| option[:group] }.uniq
    current = groups.index(@options[@selected][:group]) || 0
    target = groups[(current + delta) % groups.length]
    @selected = @options.index { |option| option[:group] == target } || @selected
    pbPlayCursorSE
  end

  def execute(option)
    if option[:action] == :peer
      @selected_peer = option[:peer]
      @mode = :peer
      focus(@desired_action || :team)
      @desired_action = nil
      return
    end
    AnilCoop.instance_variable_set(:@online_screen_active, false)
    begin
      action = option[:action]
      case action
      when :players, :teams, :trades, :battles
        peers = AnilCoop.instance_variable_get(:@peers)
        if peers.empty?
          pbMessage("Todavía no hay compañeros conectados.") { AnilCoop.tick($scene) }
        else
          @desired_action = { players: :team, teams: :team,
                              trades: :trade, battles: :pvp }[action]
          @selected_peer = peers.keys.first unless peers.key?(@selected_peer)
          focus(:peer, @selected_peer)
        end
      when :map then AnilCoop.online_locations
      when :copy then AnilCoop.copy_room_data(@status.fetch("session"))
      when :team then with_peer { |id| AnilCoop.online_view_team(id) }
      when :location then with_peer { |id| AnilCoop.online_locations(id) }
      when :trade, :pvp
        with_peer do |id|
          kind = action == :trade ? "trade" : "pvp"
          pending = AnilCoop.online_invite_pending(id, kind)
          pending ? AnilCoop.online_invite_cancel(pending) : AnilCoop.online_invite_send(id, kind)
        end
      when :back_peer
        @mode = :main
        @desired_action = nil
        focus(:peer, @selected_peer)
      when :disconnect
        if AnilCoop.confirm_online_disconnect
          AnilCoop.menu_stop
          @mode = :main
          @selected_peer = nil
          @desired_action = nil
          refresh_status(true)
        end
      when :create, :join, :paste
        AnilCoop.online_connect_choice({ create: 0, join: 1, paste: 2 }[action], @status)
        refresh_status(true)
      when :retry
        session = @status.fetch("session")
        AnilCoop.menu_start(session["mode"], session["host"], session["code"])
        refresh_status(true)
      end
    rescue StandardError => e
      pbMessage("Online: #{e.message}") { AnilCoop.battle_tick }
    ensure
      AnilCoop.instance_variable_set(:@online_screen_active, true)
    end
  end

  def with_peer
    if AnilCoop.instance_variable_get(:@peers).key?(@selected_peer)
      yield @selected_peer
    else
      @mode = :main
      pbMessage("El compañero se desconectó.") { AnilCoop.tick($scene) }
    end
  end

  def panel(bitmap, x, y, width, height)
    bitmap.fill_rect(x, y, width, height, PANEL)
    bitmap.fill_rect(x, y, width, 2, Color.new(97, 156, 248))
  end

  def label(bitmap, text, x, y, color = BASE, tiny = false)
    tiny ? pbSetTinyFont(bitmap) : pbSetSmallFont(bitmap)
    pbDrawTextPositions(bitmap, [[text.to_s, x, y, :left, color, SHADOW]])
  end

  def peer_activity(id)
    states = AnilCoop.instance_variable_get(:@trainer_states) || {}
    state = states.values.find do |entry|
      Array(entry["participants"]).any? { |member| member["id"] == id }
    end
    return "Combatiendo" if state && state["phase"] == "locked"
    return "Preparándose" if state && state["phase"] == "pending"
    "Conectado"
  end

  def draw
    bitmap = @sprites["content"].bitmap
    bitmap.clear
    peers = AnilCoop.instance_variable_get(:@peers)
    connected = AnilCoop.connected?
    panel(bitmap, 0, 0, Graphics.width, 49)
    pbSetSystemFont(bitmap)
    pbDrawTextPositions(bitmap, [["ONLINE", 18, 3, :left, GOLD, SHADOW]])
    bitmap.fill_rect(Graphics.width - 138, 17, 10, 10,
                     connected ? Color.new(97, 226, 144) : Color.new(224, 110, 110))
    label(bitmap, connected ? "CONECTADO" : "DESCONECTADO", Graphics.width - 121, 10, BASE, true)
    name = ENV["ANIL_COOP_NAME"].to_s
    label(bitmap, name.empty? ? "Sin nombre" : name, 152, 13, MUTED, true)
    panel(bitmap, 12, 56, Graphics.width - 24, 70)
    if connected
      session = @status["session"] || {}
      role = AnilCoop.speed_host? ? "Anfitrión" : "Invitado"
      label(bitmap, "SALA #{session['code'] || ENV['ANIL_COOP_SESSION']}", 22, 58, GOLD)
      label(bitmap, "#{role} · #{peers.length + 1} jugadores", 22, 82, BASE, true)
      speed = AnilCoop.instance_variable_get(:@speed_battle_lock) ? 1 : ($GameSpeed + 1)
      label(bitmap, "Velocidad ×#{speed}", 22, 100, MUTED, true)
      panel(bitmap, 12, 137, 239, 183)
      panel(bitmap, 258, 137, Graphics.width - 270, 183)
      label(bitmap, "JUGADORES", 22, 138, GOLD, true)
      label(bitmap, @mode == :peer ? "ACCIONES DEL COMPAÑERO" : "ACCESOS", 268, 138, GOLD, true)
      label(bitmap, "Ningún compañero en la sala", 23, 185, MUTED, true) if peers.empty?
    else
      label(bitmap, "SIN SALA ACTIVA", 22, 65, GOLD)
      note = @status_error ? "El auxiliar de conexión no responde." :
             @status["session"] ? "Conexión interrumpida. Podés reintentar." : "Creá una sala o uníte a tu amigo."
      label(bitmap, note, 22, 90, MUTED, true)
      panel(bitmap, 12, 137, Graphics.width - 24, 183)
      label(bitmap, "EMPEZAR", 24, 139, GOLD, true)
    end
    @options.each_with_index do |option, index|
      rect = option[:rect]
      active_peer = option[:action] == :peer && option[:peer] == @selected_peer && @mode == :peer
      selected = index == @selected
      bitmap.fill_rect(rect.x, rect.y, rect.width, rect.height,
                       selected ? SELECTED : active_peer ? Color.new(52, 91, 185, 238) : ROW)
      bitmap.fill_rect(rect.x, rect.y, 3, rect.height, GOLD) if selected
      if option[:action] == :peer
        peer = peers[option[:peer]]
        next unless peer
        label(bitmap, peer["name"].to_s[0, 19], rect.x + 12, rect.y - 1, selected ? GOLD : BASE)
        map = peer.dig("position", "map")
        zone = map && GameData::MapMetadata.exists?(map) ? GameData::MapMetadata.get(map).name : "Ubicación no disponible"
        label(bitmap, "#{peer_activity(option[:peer])} · #{zone.to_s[0, 17]}",
              rect.x + 12, rect.y + 21, MUTED, true)
      else
        label(bitmap, option[:label], rect.x + 10, rect.y + (rect.height > 30 ? 5 : 2),
              selected ? GOLD : BASE, true)
      end
    end
    label(bitmap, "↑↓ elegir   ←→ sección   Z aceptar   X volver", 20, Graphics.height - 68, MUTED, true)
  end
end
