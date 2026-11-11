# Opt-in invitation protocol check in two native engines, without OS input.
require "digest"
module AnilCoopInviteQA
  def self.wait(seconds = 12)
    deadline = Time.now.to_f + seconds
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      return if yield
      raise "invite QA deadline" if Time.now.to_f >= deadline
    end
  end

  def self.send_request(peer, code, kind)
    request = code * 16
    outgoing = AnilCoop.instance_variable_get(:@outgoing_invites) || {}
    outgoing[request] = { peer: peer, kind: kind, name: "friend" }
    AnilCoop.instance_variable_set(:@outgoing_invites, outgoing)
    AnilCoop.queue(type: "invite_request", request: request, target: peer, kind: kind)
    request
  end

  def self.wait_status(request, expected)
    wait do
      updates = AnilCoop.instance_variable_get(:@invite_updates) || []
      entry = updates.find { |item| item[0][:kind] && item[1] == expected }
      updates.delete(entry) if entry
      !!entry
    end
    raise "invite still pending" if (AnilCoop.instance_variable_get(:@outgoing_invites) || {}).key?(request)
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
    role = ENV.fetch("ANIL_COOP_ONLINE_QA_ROLE")
    code = "ABCDEFGHJKLM"
    name = role == "create" ? "client03" : "client04"
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
    wait { AnilCoop.instance_variable_get(:@peers).length == 1 }
    peer = AnilCoop.instance_variable_get(:@peers).keys.first
    if role == "create"
      first = send_request(peer, "a", "trade")
      wait_status(first, "declined")
      second = send_request(peer, "b", "pvp")
      wait_status(second, "accepted")
      third = send_request(peer, "c", "trade")
      started = Time.now.to_f
      wait(4) { Time.now.to_f - started >= 1 }
      AnilCoop.queue(type: "invite_cancel", request: third)
      wait_status(third, "cancelled")
      fourth = send_request(peer, "d", "pvp")
      wait_status(fourth, "peer_left")
      statuses = ["declined", "accepted", "cancelled", "peer_left"]
    else
      request = "a" * 16
      wait { (AnilCoop.instance_variable_get(:@incoming_invites) || {}).key?(request) }
      offer = AnilCoop.instance_variable_get(:@incoming_invites).fetch(request)
      raise "wrong invite" unless offer[:kind] == "trade" && offer[:from] == peer
      AnilCoop.queue(type: "invite_reply", request: request, accept: false)
      wait { !(AnilCoop.instance_variable_get(:@incoming_invites) || {}).key?(request) }
      $anil_invite_qa_visual = true
      request = "b" * 16
      wait do
        $anil_invite_qa_visual_seen &&
          !(AnilCoop.instance_variable_get(:@incoming_invites) || {}).key?(request)
      end
      $anil_invite_qa_visual = false
      request = "c" * 16
      wait { (AnilCoop.instance_variable_get(:@incoming_invites) || {}).key?(request) }
      wait { !(AnilCoop.instance_variable_get(:@incoming_invites) || {}).key?(request) }
      request = "d" * 16
      wait { (AnilCoop.instance_variable_get(:@incoming_invites) || {}).key?(request) }
      AnilCoop.menu_stop
      statuses = ["declined", "accepted", "cancelled", "peer_left"]
    end
    raise "save changed" unless Digest::SHA256.file(save).hexdigest == before
    result = { pass: true, role: role, statuses: statuses, save_unchanged: true }
  rescue StandardError => e
    result = { pass: false, error: "#{e.class}: #{e.message}", trace: e.backtrace.first(6) }
  ensure
    $anil_invite_qa_visual = false
    AnilCoop.menu_stop rescue nil
    File.write(File.join(AnilCoopDev::PROFILE, "qa-invites-result.json"), JSON.generate(result))
    exit
  end
end

module AnilCoopInviteQAPoll
  def online_invite_poll
    return unless $anil_invite_qa_visual
    incoming = AnilCoop.instance_variable_get(:@incoming_invites) || {}
    $anil_invite_qa_visual_seen = true if incoming.key?("b" * 16)
    super
  end
end
AnilCoop.singleton_class.prepend(AnilCoopInviteQAPoll)

module AnilCoopInviteQAInput
  def trigger?(key)
    if key == Input::USE && $anil_invite_qa_visual
      @anil_invite_qa_ready ||= Time.now.to_f + 0.7
      return false if Time.now.to_f < @anil_invite_qa_ready
      unless $anil_invite_qa_screenshot
        bitmap = Graphics.snap_to_bitmap
        bitmap.save_to_png(File.join(AnilCoopDev::PROFILE, "qa-online-invite.png"))
        bitmap.dispose
        $anil_invite_qa_screenshot = true
      end
      return true
    end
    super
  end
end
Input.singleton_class.prepend(AnilCoopInviteQAInput)

$anil_invite_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_invite_trace.disable
  AnilCoopInviteQA.run
end
$anil_invite_trace.enable
