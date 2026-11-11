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
    if role == "join"
      begin
        AnilCoop.menu_start("join", "127.0.0.1", code, name: name)
      rescue StandardError
        sleep 1
        retry if (@attempts = (@attempts || 0) + 1) < 8
        raise
      end
    else
      AnilCoop.menu_start("create", "127.0.0.1", code, name: name)
    end
    wait do
      peers = AnilCoop.instance_variable_get(:@peers)
      peers.length == 1 && peers.values.first["position"].is_a?(Hash)
    end
    $anil_online_qa_close_menu = true
    3.times do
      AnilCoop.online_menu
      raise "X disconnected Online" unless AnilCoop.connected?
      raise "X removed companion" unless AnilCoop.instance_variable_get(:@peers).length == 1
    end
    AnilCoop.online_players
    raise "X disconnected player list" unless AnilCoop.connected?
    raise "X confirmed disconnection" if AnilCoop.confirm_online_disconnect
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
      AnilCoop.menu_stop
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
    AnilCoop.menu_stop rescue nil
    File.write(File.join(AnilCoopDev::PROFILE, "qa-online-result.json"), JSON.generate(result))
    exit
  end
end

module AnilCoopOnlineQAInput
  def trigger?(key)
    if key == Input::BACK && $anil_online_qa_close_menu
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

$anil_coop_online_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_online_trace.disable
  AnilCoopOnlineQA.run
end
$anil_coop_online_trace.enable
