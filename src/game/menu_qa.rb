# Opt-in game-engine check: title entry, local helper, room handshake. No OS input.
$anil_coop_menu_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_menu_trace.disable
  result = { pass: false }
  scene = nil
  begin
    commands = ["Partida Nueva", "Cerrar Juego"]
    scene = PokemonLoad_Scene.new
    scene.pbStartScene(commands, false, nil, nil, 0)
    raise "Título sin Multijugador" unless commands == ["Partida Nueva", "Multijugador", "Cerrar Juego"]
    # Check the two-argument Multi Save API and remapping of the original Quit.
    chooser = Class.new do
      def pbChoose(_commands, continue_idx)
        raise "Índice Continuar no reenviado" unless continue_idx == 0
        2
      end
    end
    chooser.prepend(AnilCoopTitleMenu)
    raise "Cerrar Juego cambió de índice" unless chooser.new.pbChoose(commands, 0) == 1
    scene.pbStartScene2
    Graphics.update
    bitmap = Graphics.snap_to_bitmap
    bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-multiplayer-title.png"))
    bitmap.dispose
    data = AnilCoop.menu_start("create", "127.0.0.1")
    raise "No conectó desde el juego" unless AnilCoop.connected?
    raise "Sala no visible" unless AnilCoop.menu_request("status")["session"]["code"] == data["code"]
    result = { pass: true, title_entry: true, connected: true, code_length: data["code"].length }
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(5) }
  ensure
    scene&.pbEndScene
    AnilCoop.menu_stop rescue nil
    File.write(File.join(AnilCoopDev::PROFILE, "qa-multiplayer-result.json"), JSON.generate(result))
    exit
  end
end
$anil_coop_menu_trace.enable
