# Opt-in native Q/protocol check in isolated clients. No OS input or save writes.
require "digest"
module AnilCoopSpeedQA
  def self.wait(seconds = 15)
    deadline = Time.now.to_f + seconds
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      return if yield
      raise "speed QA deadline" if Time.now.to_f > deadline
    end
  end

  def self.press_q
    $anil_coop_qa_q = true
    Input.update
  ensure
    $anil_coop_qa_q = false
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
    wait { AnilCoop.speed_active? && AnilCoop.instance_variable_get(:@peers).length == 1 }
    host = AnilCoop.speed_host?
    stages = []
    if host
      [1, 2, 0, 2].each do |stage|
        3.times do
          break if $GameSpeed == stage
          press_q
        end
        raise "host Q did not reach stage #{stage}" unless $GameSpeed == stage
        AnilCoop.network
        wait(4) { AnilCoop.instance_variable_get(:@shared_speed) == stage }
        stages << [stage, SPEEDUP_STAGES[stage]]
        started = Time.now.to_f
        wait(4) { Time.now.to_f - started > 1.0 }
      end
    else
      [1, 2, 0, 2].each do |stage|
        wait { $GameSpeed == stage && AnilCoop.instance_variable_get(:@shared_speed) == stage }
        stages << [stage, SPEEDUP_STAGES[stage]]
        if stage == 1
          press_q
          raise "guest changed speed" unless $GameSpeed == 1
        end
      end
    end
    raise "incorrect shared stages" unless stages == [[1, 2], [2, 3.0], [0, 1], [2, 3.0]]
    if host
      wait { !AnilCoop.speed_active? }
      raise "native speed not restored after peer left" unless SPEEDUP_STAGES[2] == 2.5
      press_q
      raise "host Q stopped working alone" unless $GameSpeed == 0
      AnilCoop.network
      wait { AnilCoop.instance_variable_get(:@shared_speed) == 0 }
      wait { AnilCoop.speed_active? && AnilCoop.instance_variable_get(:@peers).length == 1 }
      raise "reconnected host speed mismatch" unless $GameSpeed == 0
    else
      # Let the host finish recording the final ×3 stage before leaving.
      started = Time.now.to_f
      wait(4) { Time.now.to_f - started > 2.0 }
      AnilCoop.disconnect
      raise "guest original third speed not restored" unless SPEEDUP_STAGES[2] == 2.5
      raise "guest Q remained locked after disconnect" unless $CanToggle
      press_q
      raise "guest Q stopped working after disconnect" unless $GameSpeed == 0
      started = Time.now.to_f
      Graphics.update while Time.now.to_f - started < 4
      wait { AnilCoop.speed_active? && AnilCoop.instance_variable_get(:@peers).length == 1 }
      raise "reconnected guest did not receive host speed" unless $GameSpeed == 0
    end
    result = { pass: true, host: host, stages: stages,
               reconnected: true,
               native_third: AnilCoop.instance_variable_get(:@native_third_speed),
               save_unchanged: Digest::SHA256.file(save).hexdigest == before }
    raise "save changed" unless result[:save_unchanged]
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(5) }
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-speed-result.json"), JSON.generate(result))
    exit
  end
end

module AnilCoopQAPress
  def trigger?(key)
    return true if key == Input::AUX1 && $anil_coop_qa_q
    super
  end
end
Input.singleton_class.prepend(AnilCoopQAPress)

$anil_coop_speed_trace = TracePoint.new(:return) do |trace|
  next unless trace.method_id == :set_up_system && trace.defined_class == Game.singleton_class
  $anil_coop_speed_trace.disable
  AnilCoopSpeedQA.run
end
$anil_coop_speed_trace.enable
