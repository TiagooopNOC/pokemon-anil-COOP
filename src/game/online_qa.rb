# Opt-in check in two isolated native engines. No input injection outside the game.
require "digest"
module AnilCoopOnlineQA
  def self.wait(seconds = 20)
    deadline = Time.now.to_f + seconds
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      return if yield
      raise "online QA deadline" if Time.now.to_f > deadline
    end
  end

  def self.run
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    $player.has_pokedex = true  # Exercise the eight-option layout in memory only.
    $anil_online_qa_close_menu = true
    menu = DP_PauseMenu.new
    entries = menu.instance_variable_get(:@options).map(&:first)
    raise "Online missing from native ESC menu" unless entries.include?("Online")
    raise "original menu changed" unless entries.last == "Salir" && entries[-2] == "Online"
    raise "eight-option layout missing" unless entries.length == 8
    $anil_online_qa_close_menu = false
    role = ENV.fetch("ANIL_COOP_ONLINE_QA_ROLE")
    code = "ABCDEFGHJKLM"
    name = role == "create" ? "client03" : "client04"
    $anil_online_qa_connect = true
    $anil_online_qa_close_menu = true
    AnilCoop.online_menu
    $anil_online_qa_connect = false
    $anil_online_qa_close_menu = false
    raise "screen did not create/join room" unless AnilCoop.connected?
    wait do
      peers = AnilCoop.instance_variable_get(:@peers)
      peers.length == 1 && peers.values.first["position"].is_a?(Hash)
    end
    $anil_online_qa_close_menu = true
    3.times do
      AnilCoop.online_menu
      raise "X disconnected Online" unless AnilCoop.connected?
      raise "X removed companion" unless AnilCoop.instance_variable_get(:@peers).length == 1
      raise "Online viewport leaked" unless $anil_online_qa_last_screen.instance_variable_get(:@viewport).disposed?
    end
    AnilCoop.online_players
    raise "X disconnected player list" unless AnilCoop.connected?
    raise "X confirmed disconnection" if AnilCoop.confirm_online_disconnect
    if role == "create"
      $anil_online_qa_exercise_actions = true
      AnilCoop.online_menu
      $anil_online_qa_exercise_actions = false
      raise "team action missed native scene" unless $anil_online_qa_team_opened
      raise "map action missed native scene" unless $anil_online_qa_map_opened
      raise "X did not return from peer actions" unless $anil_online_qa_peer_back
      raise "submenus disconnected Online" unless AnilCoop.connected?
      raise "Online viewport leaked after actions" unless $anil_online_qa_last_screen.instance_variable_get(:@viewport).disposed?
    else
      start = Time.now.to_f
      wait(12) { Time.now.to_f - start >= 7 }
    end
    $anil_online_qa_close_menu = false
    local_location = AnilCoop.online_map_position($game_map.map_id, $game_player.x, $game_player.y)
    raise "loaded map has no regional position" unless local_location
    raise "lab interior is on the wrong regional tile" unless AnilCoop.online_map_position(29)&.first(3) == [0, 7, 14]
    raise "unknown map guessed a location" if AnilCoop.online_map_position(999999)
    scene = AnilCoopOnlineMap.new(local_location[0], nil)
    begin
      scene.pbStartScene(false, false)
      scene.refresh_markers([[nil, name], [AnilCoop.instance_variable_get(:@peers).keys.first, "friend"]])
      sprites = scene.instance_variable_get(:@sprites)
      raise "local marker missing" unless sprites["coop_marker_0"]&.visible
      raise "remote marker missing" unless sprites["coop_marker_1"]&.visible
      raise "map entered Fly mode" unless scene.instance_variable_get(:@mode) == 0
      bitmap = Graphics.snap_to_bitmap
      bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-online-map.png"))
      bitmap.dispose
    ensure
      scene.pbEndScene if scene.instance_variable_get(:@viewport)
    end
    raise "map viewport leaked" unless scene.instance_variable_get(:@viewport).disposed?
    $anil_online_qa_close_menu = true
    AnilCoop.online_locations
    $anil_online_qa_close_menu = false
    raise "closing map lost connection" unless AnilCoop.connected?
    if role == "join"
      started = Time.now.to_f
      wait(5) { Time.now.to_f - started >= 3 }
      $anil_online_qa_disconnect = true
      $anil_online_qa_close_menu = true
      AnilCoop.online_menu
      $anil_online_qa_disconnect = false
      $anil_online_qa_close_menu = false
      raise "disconnect retained socket" if AnilCoop.connected?
      [:@sprites, :@labels, :@follower_sprites].each do |field|
        raise "disconnect retained #{field}" unless AnilCoop.instance_variable_get(field).empty?
      end
      sleep 2
      AnilCoop.menu_start("join", "127.0.0.1", code, name: name)
      wait { AnilCoop.instance_variable_get(:@peers).length == 1 }
      started = Time.now.to_f
      wait(4) { Time.now.to_f - started >= 2 }
    else
      wait { AnilCoop.instance_variable_get(:@peers).empty? }
      [:@sprites, :@labels, :@follower_sprites].each do |field|
        raise "peer leave retained #{field}" unless AnilCoop.instance_variable_get(field).empty?
      end
      wait { AnilCoop.instance_variable_get(:@peers).length == 1 }
    end
    raise "save changed" unless Digest::SHA256.file(save).hexdigest == before
    result = { pass: true, menu: entries, connected: true, reconnected: true,
               region: local_location[0], save_unchanged: true }
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(6) }
  ensure
    $anil_online_qa_close_menu = false
    $anil_online_qa_exercise_actions = false
    $anil_online_qa_connect = false
    $anil_online_qa_disconnect = false
    $anil_online_qa_confirm_yes = false
    AnilCoop.menu_stop rescue nil
    File.write(File.join(AnilCoopDev::PROFILE, "qa-online-result.json"), JSON.generate(result))
    exit
  end
end

module AnilCoopOnlineQAInput
  def repeat?(key)
    if key == Input::UP && $anil_online_qa_confirm_yes && !$anil_online_qa_up_sent
      $anil_online_qa_up_sent = true
      return true
    end
    super
  end

  def trigger?(key)
    if $anil_online_qa_confirm_yes
      return false if key == Input::BACK
      return true if key == Input::USE && $anil_online_qa_up_sent
    end
    if key == Input::BACK && $anil_online_qa_close_menu
      return false if $anil_online_qa_connect && !$anil_online_qa_connected_drawn
      return false if $anil_online_qa_exercise_actions &&
                      AnilCoop.instance_variable_get(:@online_team_pending)
      unless $anil_online_qa_menu_captured
        bitmap = Graphics.snap_to_bitmap
        bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-online-menu.png"))
        bitmap.dispose
        $anil_online_qa_menu_captured = true
      end
      return true
    end
    super
  end
end
Input.singleton_class.prepend(AnilCoopOnlineQAInput)

module AnilCoopOnlineQAScreen
  def draw
    super
    $anil_online_qa_last_screen = self
    $anil_online_qa_peer_back = true if $anil_online_qa_exercise_actions &&
                                   $anil_online_qa_actions_done && @mode == :main
    if $anil_online_qa_connect && !$anil_online_qa_connect_done
      bitmap = Graphics.snap_to_bitmap
      bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-online-disconnected.png"))
      bitmap.dispose
      $anil_online_qa_connect_done = true
      action = ENV["ANIL_COOP_ONLINE_QA_ROLE"] == "create" ? :create : :join
      execute(@options.find { |option| option[:action] == action })
      return
    end
    if $anil_online_qa_disconnect && !$anil_online_qa_disconnect_done
      $anil_online_qa_disconnect_done = true
      $anil_online_qa_up_sent = false
      $anil_online_qa_confirm_yes = true
      execute(@options.find { |option| option[:action] == :disconnect })
      $anil_online_qa_confirm_yes = false
      return
    end
    if $anil_online_qa_exercise_actions && !$anil_online_qa_actions_done
      $anil_online_qa_actions_done = true
      @selected_peer = AnilCoop.instance_variable_get(:@peers).keys.first
      @mode = :peer
      rebuild_options
      execute(@options.find { |option| option[:action] == :team })
      execute(@options.find { |option| option[:action] == :location })
      execute(@options.find { |option| option[:action] == :disconnect })
    end
    path = AnilCoop.connected? ? "qa-online-screen.png" : "qa-online-disconnected.png"
    return if ($anil_online_qa_screen_captured ||= {})[path]
    bitmap = Graphics.snap_to_bitmap
    bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, path))
    bitmap.dispose
    $anil_online_qa_screen_captured[path] = true
    $anil_online_qa_connected_drawn = true if AnilCoop.connected?
  end
end
AnilCoopOnlineScreen.prepend(AnilCoopOnlineQAScreen)

module AnilCoopOnlineQATeamScene
  def pbStartScene(*args)
    $anil_online_qa_team_opened = true
    super
  end
end
AnilCoopRemotePartyScene.prepend(AnilCoopOnlineQATeamScene)

module AnilCoopOnlineQAMapScene
  def pbStartScene(*args)
    $anil_online_qa_map_opened = true if $anil_online_qa_exercise_actions
    super
  end
end
AnilCoopOnlineMap.prepend(AnilCoopOnlineQAMapScene)

module AnilCoopOnlineQAConnect
  def online_connect_choice(choice, status)
    return super unless $anil_online_qa_connect
    role = ENV.fetch("ANIL_COOP_ONLINE_QA_ROLE")
    code = "ABCDEFGHJKLM"
    if role == "create" && choice == 0
      menu_start("create", "127.0.0.1", code, name: "client03")
    elsif role == "join" && choice == 1
      begin
        menu_start("join", "127.0.0.1", code, name: "client04")
      rescue StandardError
        sleep 1
        retry if (@attempts = (@attempts || 0) + 1) < 8
        raise
      end
    else
      raise "wrong offline action"
    end
  end
end
AnilCoop.singleton_class.prepend(AnilCoopOnlineQAConnect)

$anil_coop_online_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_online_trace.disable
  AnilCoopOnlineQA.run
end
$anil_coop_online_trace.enable
