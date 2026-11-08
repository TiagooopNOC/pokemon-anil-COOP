# Opt-in native-engine check of remote sprite motion. No saves, socket or OS input.
$anil_coop_presence_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_presence_trace.disable
  result = { pass: false }
  begin
    remote = AnilCoopRemoteCharacter.new
    pos = { "x" => 10, "y" => 10, "direction" => 2, "pattern" => 1, "speed" => 3 }
    remote.follow_network(pos, 0.0)
    raise "initial position" unless remote.real_x == 10 * Game_Map::REAL_RES_X
    remote.follow_network(pos.merge("x" => 11), 1.0)
    remote.follow_network(pos.merge("x" => 11), 1.125)
    halfway = remote.real_x
    raise "walking interpolation" unless halfway > 10 * Game_Map::REAL_RES_X && halfway < 11 * Game_Map::REAL_RES_X
    remote.follow_network(pos.merge("x" => 11), 1.25)
    raise "walking destination" unless remote.real_x == 11 * Game_Map::REAL_RES_X
    remote.follow_network(pos.merge("x" => 12, "speed" => 4, "direction" => 6), 2.0)
    remote.follow_network(pos.merge("x" => 12, "speed" => 4, "direction" => 6), 2.0625)
    raise "running interpolation" unless remote.real_x > 11 * Game_Map::REAL_RES_X && remote.real_x < 12 * Game_Map::REAL_RES_X
    remote.follow_network(pos.merge("x" => 12, "speed" => 4, "direction" => 6), 2.125)
    raise "running destination" unless remote.real_x == 12 * Game_Map::REAL_RES_X
    remote.follow_network(pos.merge("x" => 20, "speed" => 4, "direction" => 8), 3.0)
    raise "warp snap" unless remote.real_x == 20 * Game_Map::REAL_RES_X && remote.direction == 8
    result = { pass: true, walking: true, running: true, warp: true }
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(5) }
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-presence-result.json"), JSON.generate(result))
    exit
  end
end
$anil_coop_presence_trace.enable
