# Session-scoped invitations. A negotiated PvP invitation opens preparation.
require "securerandom"
module AnilCoop
  INVITE_NAMES = { "trade" => "intercambio", "pvp" => "combate PvP" }.freeze

  def self.online_invite_receive(message)
    request = message["request"]
    return unless request.is_a?(String) && request.match?(/\A[0-9a-f]{16}\z/)
    @incoming_invites ||= {}
    @outgoing_invites ||= {}
    @invite_updates ||= []
    if message["type"] == "invite_offer"
      kind, sender = message.values_at("kind", "from")
      return unless INVITE_NAMES.key?(kind) && @peers.key?(sender)
      @incoming_invites[request] = { from: sender, name: message["name"].to_s, kind: kind,
                                     pvp: pvp_enabled? && message["pvp"] == "singles-v1" }
    elsif message["type"] == "invite_state"
      status = message["status"]
      return if status == "pending"
      if (outgoing = @outgoing_invites.delete(request))
        @invite_updates << [outgoing, status] unless status == "accepted" && message["pvp"] == "singles-v1"
      end
      @incoming_invites.delete(request)
    end
  end

  def self.online_invite_pending(peer_id, kind)
    (@outgoing_invites || {}).find { |_id, entry| entry[:peer] == peer_id && entry[:kind] == kind }&.first
  end

  def self.online_invite_send(peer_id, kind)
    raise "No se puede enviar la invitación ahora." unless connected? && online_available?
    raise "El compañero se desconectó." unless @peers.key?(peer_id)
    raise "Invitación no válida." unless INVITE_NAMES.key?(kind)
    raise "Ya hay una solicitud pendiente." if online_invite_pending(peer_id, kind)
    request = SecureRandom.hex(8)
    @outgoing_invites ||= {}
    @outgoing_invites[request] = { peer: peer_id, kind: kind,
                                   name: @peers[peer_id]["name"].to_s }
    packet = { type: "invite_request", request: request, target: peer_id, kind: kind }
    packet[:pvp] = "singles-v1" if kind == "pvp" && pvp_enabled?
    queue(**packet)
    pbMessage("Invitación de #{INVITE_NAMES[kind]} enviada.") { tick($scene) }
  end

  def self.online_invite_cancel(request)
    entry = (@outgoing_invites || {})[request]
    return false unless entry
    return false unless connected?
    queue(type: "invite_cancel", request: request)
    pbMessage("Cancelación solicitada.") { tick($scene) }
    true
  end

  def self.online_invite_disconnect
    @incoming_invites = {}
    @outgoing_invites = {}
    @invite_updates = []
    @invite_modal = false
    @pvp_offer = @pvp_unavailable = nil
  end

  def self.online_invite_poll
    return if @invite_modal || !connected? || !online_available? ||
              ($game_temp.in_menu && !@online_screen_active) || $game_temp.message_window_showing ||
              $game_temp.player_transferring || @team_menu_active
    @incoming_invites ||= {}
    @invite_updates ||= []
    @invite_modal = true
    begin
      request, invite = @incoming_invites.first
      if invite
        name = @peers[invite[:from]]&.fetch("name", nil) || invite[:name]
        choice = pbMessage("#{name} te invita a un #{INVITE_NAMES[invite[:kind]]}.",
                           ["Aceptar", "Rechazar"], 1) { tick($scene) }
        if @incoming_invites.delete(request) && @peers.key?(invite[:from])
          packet = { type: "invite_reply", request: request, accept: choice == 0 }
          packet[:pvp] = "singles-v1" if invite[:pvp]
          queue(**packet)
          if choice == 0 && !invite[:pvp]
            pbMessage("Aceptaste. Esta función todavía no está disponible.") { tick($scene) }
          end
        else
          pbMessage("La invitación ya no está disponible.") { tick($scene) }
        end
      elsif (update = @invite_updates.shift)
        invite, status = update
        description = INVITE_NAMES[invite[:kind]]
        text = case status
               when "accepted" then "#{invite[:name]} aceptó el #{description}. Todavía no está disponible."
               when "declined" then "#{invite[:name]} rechazó el #{description}."
               when "expired" then "La solicitud de #{description} caducó."
               when "peer_left" then "#{invite[:name]} se desconectó; solicitud cancelada."
               when "cancelled" then "Solicitud de #{description} cancelada."
               else "No se pudo completar la solicitud de #{description}."
               end
        pbMessage(text) { tick($scene) }
      end
    ensure
      @invite_modal = false
    end
  end
end

module AnilCoopInviteTick
  def tick(scene)
    super
    online_invite_poll if respond_to?(:online_invite_poll)
    pvp_poll
  end
end
AnilCoop.singleton_class.prepend(AnilCoopInviteTick)
