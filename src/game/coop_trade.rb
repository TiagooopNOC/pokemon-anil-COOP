# Trade preparation only. Never mutates a party, inventory, save, or Pokédex.
module AnilCoop
  def self.online_trade_receive(message)
    trade = message["trade"]
    return unless trade.is_a?(String) && trade.match?(/\A[0-9a-f]{32}\z/)
    if message["type"] == "trade_error"
      @trade_error = message["reason"].to_s if trade == @trade_pending
      return
    end
    players = message["players"]
    return unless players.is_a?(Array) && players.length == 2 && players.include?(@id)
    return unless message["transfer_enabled"] == false
    return unless message["offers"].is_a?(Hash) && message["confirmed"].is_a?(Array)
    @trade_sessions ||= {}
    @trade_sessions[trade] = message
    if message["phase"] == "choosing"
      @trade_pending ||= trade
    elsif trade != @trade_pending || !@trade_modal
      @trade_ends ||= []
      @trade_ends << message["phase"]
      @trade_sessions.delete(trade)
      @trade_pending = nil if @trade_pending == trade
    end
  end

  def self.online_trade_disconnect
    @trade_sessions = {}
    @trade_pending = nil
    @trade_error = nil
    @trade_ends = []
  end

  def self.online_trade_poll
    return if @trade_modal || @invite_modal || !connected? || !online_available? ||
              ($game_temp.in_menu && !@online_screen_active) || $game_temp.message_window_showing ||
              $game_temp.player_transferring || @team_menu_active
    if @trade_pending && (@trade_sessions || {})[@trade_pending]
      trade = @trade_pending
      @trade_modal = true
      begin
        AnilCoopTradeScreen.new(trade).run
      rescue StandardError => e
        log("trade preview #{e.class}: #{e.message}")
        queue(type: "trade_cancel", trade: trade) if connected?
        pbMessage("Preparación del intercambio: #{e.message}") { battle_tick }
      ensure
        @trade_modal = false
        @trade_pending = nil if @trade_pending == trade
        @trade_sessions.delete(trade) if @trade_sessions
      end
    elsif (ending = (@trade_ends || []).shift)
      text = case ending
             when "peer_left" then "El compañero se desconectó. No se intercambió ningún Pokémon."
             when "expired" then "La preparación caducó. No se intercambió ningún Pokémon."
             when "cancelled" then "Intercambio cancelado. Los equipos no cambiaron."
             else "Preparación terminada. La transferencia todavía no está habilitada."
             end
      pbMessage(text) { battle_tick }
    end
  end

  def self.trade_eligible?(pokemon)
    pokemon && !pokemon.egg? && !pokemon.shadowPokemon? && !pokemon.cannot_trade &&
      !pokemon.fused && pokemon.moves.length > 0
  end

  def self.trade_preview_snapshot(pokemon, slot)
    team_snapshot(pokemon, slot, allow_ineligible: true).merge("egg_steps" => pokemon.steps_to_hatch)
  end
end

module AnilCoopTradeTick
  def tick(scene)
    super
    online_trade_poll if respond_to?(:online_trade_poll)
  end
end
AnilCoop.singleton_class.prepend(AnilCoopTradeTick)

class AnilCoopTradeScreen
  BASE = Color.new(245, 248, 255)
  MUTED = Color.new(190, 208, 242)
  GOLD = Color.new(255, 223, 116)
  SHADOW = Color.new(20, 35, 80)
  PANEL = Color.new(12, 39, 128, 230)
  ROW = Color.new(25, 64, 162, 232)
  SELECTED = Color.new(80, 128, 218, 245)

  def initialize(trade)
    @trade = trade
    @my_id = AnilCoop.instance_variable_get(:@id)
    @selected = 0
    @local_slot = nil
    @last_draw = 0
    @last_state = nil
  end

  def state
    (AnilCoop.instance_variable_get(:@trade_sessions) || {})[@trade]
  end

  def peer_id
    Array(state && state["players"]).find { |id| id != @my_id }
  end

  def offers
    state && state["offers"] || {}
  end

  def run
    @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
    @viewport.z = 99998
    @sprites = {}
    @sprites["background"] = IconSprite.new(0, 0, @viewport)
    @sprites["background"].setBitmap("Graphics/UI/Town Map/bg")
    @sprites["content"] = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      current = state
      break unless AnilCoop.connected? && current
      if current["phase"] != "choosing"
        text = current["phase"] == "preview_complete" ?
          "Ambos confirmaron. No se transfirió ningún Pokémon: la persistencia segura está pendiente." :
          "La preparación terminó. Los equipos no cambiaron."
        pbMessage(text) { AnilCoop.battle_tick }
        break
      end
      if (error = AnilCoop.instance_variable_get(:@trade_error))
        AnilCoop.instance_variable_set(:@trade_error, nil)
        pbMessage("Solicitud rechazada: #{error}. Revisá la propuesta.") { AnilCoop.battle_tick }
      end
      signature = [current["version"], current["confirmed"], @selected, @local_slot]
      if signature != @last_state || Time.now.to_f - @last_draw > 0.5
        draw
        @last_state = signature
        @last_draw = Time.now.to_f
      end
      @sprites["mine"]&.update
      @sprites["theirs"]&.update
      if Input.trigger?(Input::BACK)
        cancel
        break
      elsif Input.repeat?(Input::UP) || Input.repeat?(Input::LEFT)
        @selected = (@selected - 1) % 5
        pbPlayCursorSE
      elsif Input.repeat?(Input::DOWN) || Input.repeat?(Input::RIGHT)
        @selected = (@selected + 1) % 5
        pbPlayCursorSE
      elsif Input.trigger?(Input::USE)
        case @selected
        when 0 then select_offer
        when 1 then inspect_offer(offers[@my_id], @my_id)
        when 2 then inspect_offer(offers[peer_id], peer_id)
        when 3 then confirm
        when 4
          cancel
          break
        end
      end
    end
  ensure
    pbDisposeSpriteHash(@sprites) if @sprites
    @viewport.dispose if @viewport && !@viewport.disposed?
  end

  def select_offer
    peer = peer_id
    raise "El compañero se desconectó." unless peer && AnilCoop.instance_variable_get(:@peers).key?(peer)
    scene = AnilCoopRemotePartyScene.new(peer)
    AnilCoop.instance_variable_set(:@team_menu_active, true)
    pbFadeOutIn(99999) do
      begin
        scene.pbStartScene($player.party, "Elegí un Pokémon para ofrecer.", nil, true)
        loop do
          slot = scene.pbChoosePokemon
          break if slot < 0
          next if slot >= $player.party.length
          pokemon = $player.party[slot]
          unless AnilCoop.trade_eligible?(pokemon)
            scene.pbDisplay("Este Pokémon no puede intercambiarse.")
            next
          end
          choice = scene.pbShowCommands("¿Qué hacer con #{pokemon.name}?",
                                        ["Ofrecer", "Datos", "Cancelar"])
          if choice == 1
            scene.pbSummary(slot)
          elsif choice == 0
            @local_slot = slot
            AnilCoop.queue(type: "trade_offer", trade: @trade,
                           offer: AnilCoop.trade_preview_snapshot(pokemon, slot))
            break
          end
        end
      ensure
        scene.closing = true
        scene.pbEndScene if scene.instance_variable_get(:@viewport) &&
          !scene.instance_variable_get(:@viewport).disposed?
      end
    end
  ensure
    AnilCoop.instance_variable_set(:@team_menu_active, false)
  end

  def inspect_offer(offer, owner)
    unless offer
      pbMessage("Ese jugador aún no eligió un Pokémon.") { AnilCoop.battle_tick }
      return
    end
    pokemon = AnilCoop.view_team_pokemon(offer)
    scene = AnilCoopRemoteSummaryScene.new(peer_id)
    screen = PokemonSummaryScreen.new(scene, true, false)
    pbFadeOutIn(99999) { screen.pbStartScreen([pokemon], 0) }
  ensure
    if scene
      scene.closing = true
      scene.pbEndScene if scene.instance_variable_get(:@viewport) &&
        !scene.instance_variable_get(:@viewport).disposed?
    end
  end

  def confirm
    current = state
    return unless current
    mine, theirs = offers.values_at(@my_id, peer_id)
    unless mine && theirs
      pbMessage("Esperá a que ambos elijan un Pokémon.") { AnilCoop.battle_tick }
      return
    end
    pokemon = $player.party[@local_slot] if @local_slot
    unless AnilCoop.trade_eligible?(pokemon) &&
           AnilCoop.trade_preview_snapshot(pokemon, @local_slot) == mine
      pbMessage("Tu Pokémon cambió. Elegilo otra vez antes de confirmar.") { AnilCoop.battle_tick }
      @local_slot = nil
      return
    end
    choice = pbMessage("¿Confirmar esta propuesta? Todavía no se transferirán Pokémon.",
                       ["Sí", "No"], -1, nil, 1) { AnilCoop.battle_tick }
    latest = state
    if choice == 0 && latest && latest["version"] == current["version"] &&
       latest["offers"] == current["offers"]
      AnilCoop.queue(type: "trade_confirm", trade: @trade, version: current["version"])
    elsif choice == 0
      pbMessage("La propuesta cambió mientras confirmabas. Revisala otra vez.") { AnilCoop.battle_tick }
    end
  end

  def cancel
    AnilCoop.queue(type: "trade_cancel", trade: @trade) if AnilCoop.connected?
  end

  def icon(key, pokemon, x, y)
    sprite = @sprites[key]
    if sprite && sprite.pokemon != pokemon
      sprite.dispose
      @sprites.delete(key)
      sprite = nil
    end
    if pokemon && !sprite
      sprite = PokemonIconSprite.new(pokemon, @viewport)
      sprite.x = x
      sprite.y = y
      sprite.z = 2
      @sprites[key] = sprite
    end
  end

  def text(bitmap, value, x, y, color = BASE, tiny = false)
    tiny ? pbSetTinyFont(bitmap) : pbSetSmallFont(bitmap)
    pbDrawTextPositions(bitmap, [[value.to_s, x, y, :left, color, SHADOW]])
  end

  def card(bitmap, x, offer, owner_id, title)
    bitmap.fill_rect(x, 68, 238, 176, PANEL)
    bitmap.fill_rect(x, 68, 238, 2, GOLD)
    text(bitmap, title, x + 11, 73, GOLD, true)
    name = owner_id == @my_id ? ENV["ANIL_COOP_NAME"] :
           AnilCoop.instance_variable_get(:@peers).dig(owner_id, "name")
    unless offer
      text(bitmap, name.to_s[0, 18], x + 11, 92, MUTED, true)
      text(bitmap, "Sin Pokémon elegido", x + 11, 162, BASE, true)
      return
    end
    @preview_cache ||= {}
    cached = @preview_cache[owner_id]
    unless cached && cached[0] == offer
      cached = [offer, AnilCoop.view_team_pokemon(offer)]
      @preview_cache[owner_id] = cached
    end
    pokemon = cached[1]
    text(bitmap, "#{name.to_s[0, 10]} · EO #{pokemon.owner.name.to_s[0, 10]}",
         x + 11, 92, MUTED, true)
    icon(owner_id == @my_id ? "mine" : "theirs", pokemon, x + 92, 115)
    text(bitmap, pokemon.name.to_s[0, 16], x + 11, 166)
    text(bitmap, "#{pokemon.speciesName}  Nv.#{pokemon.level}", x + 11, 188, MUTED, true)
    item = pokemon.item_id ? GameData::Item.get(pokemon.item_id).name : "Sin objeto"
    text(bitmap, item.to_s[0, 25], x + 11, 207, MUTED, true)
    ready = Array(state["confirmed"]).include?(owner_id) ? "Confirmado" : "Sin confirmar"
    text(bitmap, ready, x + 11, 224, ready == "Confirmado" ? GOLD : MUTED, true)
  end

  def draw
    bitmap = @sprites["content"].bitmap
    bitmap.clear
    bitmap.fill_rect(0, 0, Graphics.width, 50, PANEL)
    pbSetSystemFont(bitmap)
    pbDrawTextPositions(bitmap, [["INTERCAMBIO", 17, 3, :left, GOLD, SHADOW]])
    text(bitmap, "Preparación · no transfiere Pokémon", 18, 31, MUTED, true)
    card(bitmap, 12, offers[@my_id], @my_id, "TU OFERTA")
    card(bitmap, 262, offers[peer_id], peer_id, "RECIBIRÍAS")
    labels = ["Elegir / cambiar Pokémon", "Ver mis datos", "Ver datos del compañero",
              "Confirmar propuesta", "Cancelar"]
    labels.each_with_index do |label, i|
      x = i.even? ? 12 : 262
      y = 251 + (i / 2) * 31
      width = i == 4 ? Graphics.width - 24 : 238
      bitmap.fill_rect(x, y, width, 29, i == @selected ? SELECTED : ROW)
      bitmap.fill_rect(x, y, 3, 29, GOLD) if i == @selected
      text(bitmap, label, x + 11, y + 3, i == @selected ? GOLD : BASE, true)
    end
    text(bitmap, "↑↓ elegir   Z aceptar   X cancelar", 18, Graphics.height - 31, MUTED, true)
  end
end
