# Read-only, on-demand party projection. No remote Pokémon enters either save.
require "securerandom"

module AnilCoop
  def self.online_team_receive(message)
    request = message["request"]
    return unless request.is_a?(String) && request.match?(/\A[0-9a-f]{16}\z/)
    case message["type"]
    when "team_view_query"
      if !online_available? || !$player || $player.party.length > 6
        queue(type: "team_view_reply", request: request, reason: "busy")
      else
        begin
          queue(type: "team_view_reply", request: request, team: view_team_snapshot)
        rescue StandardError => e
          log("team view snapshot #{e.class}: #{e.message}")
          queue(type: "team_view_reply", request: request, reason: "busy")
        end
      end
    when "team_view_data", "team_view_error"
      pending = @online_team_pending
      return unless pending && pending[:request] == request
      return if message["type"] == "team_view_data" && message["from"] != pending[:peer]
      pending[:response] = message
    end
  end

  def self.online_team_fetch(peer_id)
    raise "El compañero se desconectó." unless @peers.key?(peer_id)
    raise "Ya hay una consulta en curso." if @online_team_pending
    request = SecureRandom.hex(8)
    pending = { request: request, peer: peer_id, response: nil }
    @online_team_pending = pending
    queue(type: "team_view_request", request: request, target: peer_id)
    deadline = Time.now.to_f + 12
    loop do
      Graphics.update
      Input.update
      tick($scene)
      response = pending[:response]
      if response
        if response["type"] == "team_view_error"
          reason = { "busy" => "El compañero no puede mostrar su equipo ahora.",
                     "peer_left" => "El compañero se desconectó.",
                     "unavailable" => "No se pudo consultar al compañero.",
                     "invalid_team" => "El equipo recibido no es compatible." }
          raise(reason.fetch(response["reason"], "La consulta fue rechazada."))
        end
        data = response["team"]
        raise "Equipo recibido inválido." unless data.is_a?(Array) && data.length <= 6
        return data.map { |entry| view_team_pokemon(entry) }
      end
      raise "El compañero se desconectó." unless connected? && @peers.key?(peer_id)
      if Input.trigger?(Input::BACK) || Time.now.to_f >= deadline
        queue(type: "team_view_cancel", request: request) if connected?
        raise "Consulta cancelada o agotada. Podés reintentar."
      end
    end
  ensure
    @online_team_pending = nil if @online_team_pending.equal?(pending)
  end

  def self.online_view_team(peer_id)
    peer = @peers[peer_id]
    unless peer
      pbMessage("El compañero se desconectó.")
      return
    end
    party = online_team_fetch(peer_id)
    if party.empty?
      pbMessage("#{peer['name']} no tiene Pokémon en su equipo.")
      return
    end
    scene = AnilCoopRemotePartyScene.new(peer_id)
    pbFadeOutIn(99999) do
      begin
        scene.pbStartScene(party, "Equipo de #{peer['name']} (solo lectura).")
        loop do
          slot = scene.pbChoosePokemon
          break if slot < 0
          scene.pbSummary(slot) if slot < party.length
        end
      ensure
        scene.closing = true
        scene.pbEndScene if scene.instance_variable_get(:@viewport) &&
          !scene.instance_variable_get(:@viewport).disposed?
      end
    end
  rescue AnilCoopRemotePartyScene::PeerLeft
    pbMessage("El compañero se desconectó. Se cerró la consulta.")
  rescue StandardError => e
    pbMessage("Equipo remoto: #{e.message}")
  end
end

class AnilCoopRemoteSummaryScene < PokemonSummary_Scene
  class PeerLeft < StandardError; end
  attr_accessor :closing

  def initialize(peer_id)
    @peer_id = peer_id
  end

  def pbUpdate
    AnilCoop.tick($scene)
    raise PeerLeft unless @closing || AnilCoop.instance_variable_get(:@peers).key?(@peer_id)
    super
  end

  # Modular UI invokes custom handlers before its normal Options branch.
  # Block all extension actions; allow only the native move-detail cursor.
  def pbPageCustomUse(_page_id); false; end
  def pbPageCustomOption(_command); false; end
  def pbOptions
    return false unless @page_id == :page_moves
    @allow_learn_moves = false
    pbMoveSelection
    true
  end
  def pbRibbonSelection; end
end

class AnilCoopRemotePartyScene < PokemonParty_Scene
  class PeerLeft < StandardError; end
  attr_accessor :closing

  def initialize(peer_id)
    @peer_id = peer_id
  end

  def update
    AnilCoop.tick($scene)
    raise PeerLeft unless @closing || AnilCoop.instance_variable_get(:@peers).key?(@peer_id)
    super
  end

  def pbSummary(slot, _inbattle = false)
    oldsprites = pbFadeOutAndHide(@sprites)
    summary = AnilCoopRemoteSummaryScene.new(@peer_id)
    screen = PokemonSummaryScreen.new(summary, true, false)
    begin
      screen.pbStartScreen(@party, slot)
    ensure
      summary.closing = true
      if summary.instance_variable_get(:@viewport) && !summary.instance_variable_get(:@viewport).disposed?
        summary.pbEndScene
      end
      pbRefresh
      pbFadeInAndShow(@sprites, oldsprites)
    end
  rescue AnilCoopRemoteSummaryScene::PeerLeft
    raise PeerLeft
  end
end
