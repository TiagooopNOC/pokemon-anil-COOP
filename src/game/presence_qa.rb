# Opt-in native-engine check of ordered remote steps. No saves or OS input.
require "digest"
module AnilCoopPresenceQA
  def self.followers_run
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    sender = ENV["ANIL_COOP_NAME"] == "client03"
    deadline = System.uptime + 35
    loop do
      Graphics.update
      AnilCoop.tick($scene)
      break if AnilCoop.connected? && AnilCoop.instance_variable_get(:@peers).length == 1
      raise "follower peer timeout" if System.uptime > deadline
    end
    if sender
      $player.party << Pokemon.new(:BULBASAUR, 7) if !$player.first_able_pokemon
      event = RPG::Event.new($game_player.x - 1, $game_player.y)
      event.id = 9001
      event.name = "FollowingPkmn Co-op QA"
      game_event = Game_Event.new($game_map.map_id, event, $game_map)
      $game_map.events[9001] = game_event
      FollowingPkmn.start_following(9001, false)
      follower = FollowingPkmn.get_event
      raise "native follower missing" unless follower && !follower.character_name.to_s.empty?
      follower.through = true
      $game_player.through = true
      initial_follower = [follower.x, follower.y]
      start = System.uptime
      route = [[0.35, 6], [0.65, 6], [0.95, 2], [1.25, 4], [1.55, 8]]
      next_step = 0
      while System.uptime - start < 2.1
        Graphics.update
        follower.update
        $game_player.update
        if next_step < route.length && System.uptime - start >= route[next_step][0]
          $game_player.move_generic(route[next_step][1])
          $game_temp.followers.move_followers
          next_step += 1
        end
        AnilCoop.tick($scene)
      end
      raise "follower route incomplete" unless next_step == route.length
      raise "native follower did not follow" if [follower.x, follower.y] == initial_follower
      FollowingPkmn.stop_following
      deadline = System.uptime + 2
      while System.uptime < deadline
        Graphics.update
        AnilCoop.tick($scene)
      end
      sprite_name = follower.character_name
      $game_map.events.delete(9001)
    else
      seen = false
      movement = false
      partial = false
      ordered_steps = false
      previous = nil
      hidden = false
      deadline = System.uptime + 9
      while System.uptime < deadline
        Graphics.update
        AnilCoop.tick($scene)
        remote = AnilCoop.instance_variable_get(:@peers).values.first
        sent_steps = remote && remote["position"] && remote["position"]["follower"] &&
                     remote["position"]["follower"]["steps"]
        ordered_steps ||= sent_steps.is_a?(Array) && !sent_steps.empty?
        sprites = AnilCoop.instance_variable_get(:@follower_sprites)
        sprite = sprites.values.first
        if sprite && !sprite.disposed?
          seen = true
          point = [sprite.character.real_x, sprite.character.real_y]
          if previous
            dx, dy = (point[0] - previous[0]).abs, (point[1] - previous[1]).abs
            raise "diagonal follower frame" if dx > 0.001 && dy > 0.001
            raise "follower teleported in frame" if dx > Game_Map::REAL_RES_X * 0.95 ||
                                                 dy > Game_Map::REAL_RES_Y * 0.95
            movement ||= dx > 0.001 || dy > 0.001
            partial ||= (dx > 0.001 && dx < Game_Map::REAL_RES_X * 0.5) ||
                        (dy > 0.001 && dy < Game_Map::REAL_RES_Y * 0.5)
          end
          previous = point
          sprite_name = sprite.character.character_name
          unless @follower_screenshot
            bitmap = Graphics.snap_to_bitmap
            bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-peer-follower.png"))
            bitmap.dispose
            @follower_screenshot = true
          end
        elsif seen
          hidden = true
          break
        end
      end
      raise "remote follower not seen" unless seen
      raise "remote follower did not move" unless movement
      raise "remote follower did not interpolate" unless partial
      raise "native follower steps not sent" unless ordered_steps
      raise "remote follower not removed" unless hidden
      AnilCoop.clear_sprites
      raise "follower survived sprite reset" unless AnilCoop.instance_variable_get(:@follower_sprites).empty?
    end
    raise "save changed" unless Digest::SHA256.file(save).hexdigest == before
    { pass: true, sender: sender, sprite: sprite_name, moved: sender ? true : movement,
      hidden: sender ? true : hidden, ordered_steps: sender ? true : ordered_steps,
      save_unchanged: true }
  end

  def self.labels_run
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    deadline = System.uptime + 35
    loop do
      Graphics.update
      AnilCoop.tick($scene)
      peers = AnilCoop.instance_variable_get(:@peers)
      labels = AnilCoop.instance_variable_get(:@labels)
      break if AnilCoop.connected? && peers.length == 1 && labels.length == 1
      raise "peer label timeout" if System.uptime > deadline
    end
    id, peer = AnilCoop.instance_variable_get(:@peers).first
    sprite = AnilCoop.instance_variable_get(:@sprites).fetch(id)
    label = AnilCoop.instance_variable_get(:@labels).fetch(id)
    raise "peer label name" unless label[:name] == peer["name"]
    raise "peer label position" unless label[:sprite].x + label[:sprite].bitmap.width / 2 == sprite.x &&
      label[:sprite].y < sprite.y - sprite.oy * sprite.zoom_y
    bitmap = Graphics.snap_to_bitmap
    bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-peer-label.png"))
    bitmap.dispose
    marker = Struct.new(:map_id, :id).new($game_map.map_id, 9000)
    AnilCoop.trainer_send("trainer_wait", marker, forced: false)
    deadline = System.uptime + 10
    loop do
      Graphics.update
      AnilCoop.tick($scene)
      state = AnilCoop.instance_variable_get(:@trainer_states)[[marker.map_id, marker.id]]
      break if state && state["participants"].length == 2
      raise "label cleanup barrier timeout" if System.uptime > deadline
    end
    AnilCoop.clear_sprites
    raise "label survived map sprite reset" unless AnilCoop.instance_variable_get(:@labels).empty?
    AnilCoop.tick($scene)
    raise "label did not return" unless AnilCoop.instance_variable_get(:@labels).key?(id)
    AnilCoop.trainer_send("trainer_ready", marker, ready: true)
    deadline = System.uptime + 10
    loop do
      Graphics.update
      AnilCoop.tick($scene)
      state = AnilCoop.instance_variable_get(:@trainer_states)[[marker.map_id, marker.id]]
      break if state && state["participants"].length == 2 &&
        state["participants"].all? { |participant| participant["ready"] }
      raise "label disconnect barrier timeout" if System.uptime > deadline
    end
    release_at = System.uptime + 2
    while System.uptime < release_at
      Graphics.update
      AnilCoop.tick($scene)
    end
    AnilCoop.disconnect
    raise "label survived disconnect" unless AnilCoop.instance_variable_get(:@labels).empty?
    raise "save changed" unless Digest::SHA256.file(save).hexdigest == before
    { pass: true, peer_name: peer["name"], centered: true, reset_cleanup: true,
      reconnect_sprite: true, disconnect_cleanup: true, save_unchanged: true }
  end

  def self.network_run
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    deadline = System.uptime + 35
    loop do
      Graphics.update
      AnilCoop.tick($scene)
      peers = AnilCoop.instance_variable_get(:@peers)
      break if AnilCoop.connected? && peers.length == 1 && peers.values.first["position"]
      raise "peer connection timeout" if System.uptime > deadline
    end
    sender = ENV["ANIL_COOP_NAME"] == "client03"
    route = [[0.18, 6, 3.5], [0.36, 6, 3.5],
             [0.68, 4, 5.5], [0.725, 4, 5.5], [0.77, 4, 5.5],
             [1.10, 6, 3.5], [1.28, 2, 3.5],
             [1.60, 6, 5.5], [1.645, 2, 5.5], [1.69, 4, 5.5], [1.735, 8, 5.5],
             [2.10, 8, 5.5]]
    remote_position = AnilCoop.instance_variable_get(:@peers).values.first["position"]
    start_x, start_y = sender ? [$game_player.x, $game_player.y] :
                                [remote_position["x"], remote_position["y"]]
    expected_x, expected_y = start_x, start_y
    route.each do |(_, dir, _)|
      expected_x += (dir == 6 ? 1 : dir == 4 ? -1 : 0)
      expected_y += (dir == 2 ? 1 : dir == 8 ? -1 : 0)
    end
    started = System.uptime
    $game_player.through = true if sender
    next_step = 0
    samples = 0
    partial = 0
    previous = nil
    seen_multi = false
    while System.uptime - started < 3.2
      Graphics.update
      elapsed = System.uptime - started
      if sender
        while next_step < route.length && elapsed >= route[next_step][0]
          _, dir, speed = route[next_step]
          $game_player.move_speed = speed
          before_step = [$game_player.x, $game_player.y]
          $game_player.move_generic(dir)
          raise "scripted step blocked" if before_step == [$game_player.x, $game_player.y]
          next_step += 1
        end
      end
      AnilCoop.tick($scene)
      next if sender
      peer = AnilCoop.instance_variable_get(:@peers).values.first
      seen_multi ||= peer && peer["position"] && peer["position"]["steps"].is_a?(Array) &&
                     peer["position"]["steps"].length > 1
      sprite = AnilCoop.instance_variable_get(:@sprites).values.first
      next unless sprite && !sprite.disposed?
      character = sprite.character
      point = [character.real_x, character.real_y]
      if previous
        dx, dy = (point[0] - previous[0]).abs, (point[1] - previous[1]).abs
        raise "diagonal visual frame" if dx > 0.001 && dy > 0.001
        raise "teleport visual frame" if dx > Game_Map::REAL_RES_X * 0.95 || dy > Game_Map::REAL_RES_Y * 0.95
        partial += 1 if (dx > 0.001 && dx < Game_Map::REAL_RES_X * 0.5) ||
                        (dy > 0.001 && dy < Game_Map::REAL_RES_Y * 0.5)
      end
      previous = point
      samples += 1
    end
    raise "route incomplete" if sender && next_step != route.length
    unless sender
      character = AnilCoop.instance_variable_get(:@sprites).values.first&.character
      raise "remote endpoint" unless character && character.x == expected_x && character.y == expected_y
      raise "insufficient animation samples" unless samples > 30 && partial > 8
      raise "running steps not batched" unless seen_multi
    end
    raise "save changed" unless Digest::SHA256.file(save).hexdigest == before
    { pass: true, sender: sender, route_steps: route.length, samples: samples, partial: partial,
      ordered_batch: seen_multi, save_unchanged: true }
  end
end

$anil_coop_presence_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_presence_trace.disable
  result = { pass: false }
  begin
    if ENV["ANIL_COOP_PRESENCE_QA"] == "followers"
      result = AnilCoopPresenceQA.followers_run
    elsif ENV["ANIL_COOP_PRESENCE_QA"] == "labels"
      result = AnilCoopPresenceQA.labels_run
    elsif ENV["ANIL_COOP_PRESENCE_QA"] == "network"
      result = AnilCoopPresenceQA.network_run
    else
    remote = AnilCoopRemoteCharacter.new
    base = { "map" => 1, "x" => 10, "y" => 10, "direction" => 6,
             "pattern" => 0, "speed" => 3.5, "seq" => 0, "steps" => [], "warp" => true }
    remote.follow_network(base, 0.0)
    raise "initial position" unless remote.real_x == 10 * Game_Map::REAL_RES_X
    cases = [
      ["walk_straight", 1.0, 1.50, { "x" => 12, "y" => 10, "steps" => [6, 6], "speed" => 3.5 }],
      ["run_straight", 2.0, 2.25, { "x" => 15, "y" => 10, "steps" => [6, 6, 6], "speed" => 5.5 }],
      ["walk_turn", 3.0, 3.50, { "x" => 16, "y" => 11, "steps" => [6, 2], "speed" => 3.5 }],
      ["run_turn", 4.0, 4.30, { "x" => 16, "y" => 13, "steps" => [6, 2, 4, 2], "speed" => 5.5 }],
      ["stop", 5.0, 5.20, { "x" => 16, "y" => 13, "steps" => [], "speed" => 5.5 }],
      ["restart", 6.0, 6.20, { "x" => 16, "y" => 12, "steps" => [8], "speed" => 5.5 }]
    ]
    cases.each_with_index do |(name, start_t, end_t, update), i|
      packet = base.merge(update).merge("seq" => i + 1, "warp" => false)
      previous = [remote.real_x, remote.real_y]
      t = start_t
      while t <= end_t + 0.0001
        remote.follow_network(packet, t)
        current = [remote.real_x, remote.real_y]
        dx, dy = (current[0] - previous[0]).abs, (current[1] - previous[1]).abs
        raise "#{name} diagonal" if dx > 0.001 && dy > 0.001
        raise "#{name} snapped" if dx > Game_Map::REAL_RES_X * 0.3 || dy > Game_Map::REAL_RES_Y * 0.3
        previous = current
        t += 0.005
      end
      raise "#{name} destination" unless remote.real_x == packet["x"] * Game_Map::REAL_RES_X &&
                                          remote.real_y == packet["y"] * Game_Map::REAL_RES_Y
      base = packet
    end
    remote.follow_network(base.merge("seq" => 7, "x" => 20, "y" => 20, "steps" => [], "warp" => true), 7.0)
    raise "warp snap" unless remote.real_x == 20 * Game_Map::REAL_RES_X && remote.real_y == 20 * Game_Map::REAL_RES_Y
    result = { pass: true, cases: cases.map(&:first), warp: true }
    end
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(5) }
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-presence-result.json"), JSON.generate(result))
    exit
  end
end
$anil_coop_presence_trace.enable
