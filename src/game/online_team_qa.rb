# Opt-in two-engine read-only party check. All changes stay in memory.
require "digest"
module AnilCoopOnlineTeamQA
  def self.wait(seconds = 15)
    deadline = Time.now.to_f + seconds
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      return if yield
      raise "team view QA deadline" if Time.now.to_f >= deadline
    end
  end

  def self.run
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before_hash = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    $game_player.refresh
    $scene.createSpritesets
    Graphics.transition(0)
    role = ENV.fetch("ANIL_COOP_ONLINE_QA_ROLE")
    name = role == "create" ? "client03" : "client04"
    code = "ABCDEFGHJKLM"
    if role == "create"
      AnilCoop.menu_start("create", "127.0.0.1", code, name: name)
    else
      begin
        AnilCoop.menu_start("join", "127.0.0.1", code, name: name)
      rescue StandardError
        sleep 1
        retry if (@attempts = (@attempts || 0) + 1) < 8
        raise
      end
    end
    wait do
      peers = AnilCoop.instance_variable_get(:@peers)
      peers.length == 1 && peers.values.first["position"].is_a?(Hash)
    end
    peer_id = AnilCoop.instance_variable_get(:@peers).keys.first
    if role == "create"
      first = AnilCoop.online_team_fetch(peer_id)
      raise "first team empty" if first.empty?
      started = Time.now.to_f
      wait(7) { Time.now.to_f - started >= 3 }
      remote = AnilCoop.online_team_fetch(peer_id)
      raise "fresh query did not reflect six-slot party" unless remote.length == 6 && first.length == 1
      raise "fainted slot lost HP" unless remote[2].hp == 0
      raise "egg slot lost hatch state" unless remote[3].egg?
    else
      started = Time.now.to_f
      wait(5) { Time.now.to_f - started >= 2 }
      5.times { $player.party << Pokemon.new(:SQUIRTLE, 7) }
      $player.party[2].hp = 0
      $player.party[3].steps_to_hatch = 1800
      remote = AnilCoop.online_team_fetch(peer_id)
      raise "remote team empty" if remote.empty?
    end
    local_before_view = AnilCoop.view_team_snapshot
    scene = AnilCoopRemotePartyScene.new(peer_id)
    begin
      scene.pbStartScene(remote, "Equipo remoto (solo lectura).")
      bitmap = Graphics.snap_to_bitmap
      bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-online-team.png"))
      bitmap.dispose
      $anil_online_team_qa_summary_path = "qa-online-summary.png"
      $anil_online_team_qa_close = true
      scene.pbSummary(0)
      $anil_online_team_qa_summary_path = "qa-online-moves.png"
      moves_scene = AnilCoopRemoteSummaryScene.new(peer_id)
      PokemonSummaryScreen.new(moves_scene, true, false).pbStartScreen(remote, 0, 5)
      $anil_online_team_qa_close = false
      raise "summary modified local party" unless AnilCoop.view_team_snapshot == local_before_view
      if role == "create"
        begin
          wait(10) { scene.update; false }
          raise "remote disconnect did not close view"
        rescue AnilCoopRemotePartyScene::PeerLeft
          # Expected: the scene exits without retaining a remote team in a save.
        end
      else
        started = Time.now.to_f
        wait(6) { Time.now.to_f - started >= 3 }
        AnilCoop.menu_stop
      end
    ensure
      $anil_online_team_qa_close = false
      scene.closing = true
      scene.pbEndScene if scene.instance_variable_get(:@viewport) &&
        !scene.instance_variable_get(:@viewport).disposed?
    end
    raise "save changed" unless Digest::SHA256.file(save).hexdigest == before_hash
    result = { pass: true, role: role, local_species: $player.party.map { |p| p.species.to_s },
               remote_species: remote.map { |p| p.species.to_s }, remote_count: remote.length,
               randomizer: RandomizedChallenge.enabled?, save_unchanged: true }
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(6) }
  ensure
    $anil_online_team_qa_close = false
    AnilCoop.menu_stop rescue nil
    File.write(File.join(AnilCoopDev::PROFILE, "qa-online-team-result.json"), JSON.generate(result))
    exit
  end
end

module AnilCoopOnlineTeamQAInput
  def trigger?(key)
    return true if key == Input::BACK && $anil_online_team_qa_close
    super
  end
end
Input.singleton_class.prepend(AnilCoopOnlineTeamQAInput)

module AnilCoopOnlineTeamQASummaryCapture
  def pbStartScene(*args)
    result = super
    bitmap = Graphics.snap_to_bitmap
    bitmap.save_to_png(File.join(AnilCoopDev::PROFILE,
      $anil_online_team_qa_summary_path || "qa-online-summary.png"))
    bitmap.dispose
    result
  end
end
AnilCoopRemoteSummaryScene.prepend(AnilCoopOnlineTeamQASummaryCapture)

$anil_online_team_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_online_team_trace.disable
  AnilCoopOnlineTeamQA.run
end
$anil_online_team_trace.enable
