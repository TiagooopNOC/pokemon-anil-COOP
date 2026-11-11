module AnilCoop
  # MapPosition is authoritative for interiors too. Never guess from a previous
  # outdoor position: some story maps and caves have no reliable map marker.
  def self.online_map_position(map_id, x = nil, y = nil)
    return nil unless map_id.is_a?(Integer) && GameData::MapMetadata.exists?(map_id)
    metadata = GameData::MapMetadata.get(map_id)
    position = metadata.town_map_position
    return nil unless position && position.length == 3
    region, map_x, map_y = position
    return nil unless GameData::TownMap.exists?(region)
    size = metadata.town_map_size
    if size && size[0].to_i > 1 && x.is_a?(Integer) && y.is_a?(Integer) &&
       $game_map && map_id == $game_map.map_id
      width, height = $game_map.width, $game_map.height
      if width > 0 && height > 0
        map_x += (x * size[0] / width).floor
        map_y += (y * (size[1].length.to_f / size[0]).ceil / height).floor
      end
    end
    return nil unless (0..29).include?(map_x) && (0..19).include?(map_y)
    [region, map_x, map_y, metadata.name]
  end

  def self.online_locations(selected_id = nil)
    loop do
      players = online_map_players
      index = players.index { |entry| entry[0] == selected_id } || 0
      map_id = selected_id ? @peers.dig(selected_id, "position", "map") : $game_map.map_id
      position = selected_id ? @peers.dig(selected_id, "position") : nil
      location = online_map_position(map_id, position && position["x"], position && position["y"])
      unless location
        pbMessage("#{players[index][1]}: ubicación no disponible para este mapa.")
        return
      end
      result = nil
      pbFadeOutIn(99999) do
        scene = AnilCoopOnlineMap.new(location[0], selected_id)
        begin
          if scene.pbStartScene(false, false) != false
            result = scene.online_loop(players)
          end
        ensure
          scene.pbEndScene if scene.instance_variable_get(:@viewport)
        end
      end
      next if result == :region_change
      return unless result == :next || result == :previous
      index = (index + (result == :next ? 1 : -1)) % players.length
      selected_id = players[index][0]
    end
  end

  def self.online_map_players
    [[nil, ENV["ANIL_COOP_NAME"].to_s.empty? ? "Vos" : ENV["ANIL_COOP_NAME"]]] +
      @peers.values.map { |peer| [peer["id"], peer["name"].to_s] }
  end
end

# Uses Añil's own regional map scene and trainer map-head artwork. It is
# informational: the native fly command loop is never entered.
class AnilCoopOnlineMap < PokemonRegionMap_Scene
  def initialize(region, selected_id)
    super(region, true)
    @selected_id = selected_id
    @marker_ids = []
  end

  def pbStartScene(as_editor = false, fly_map = false)
    result = super(as_editor, false)
    return result if result == false
    # The Pokegear theme forces region 0 when the current map has no MapPosition.
    # In this read-only view the selected player's known region takes precedence.
    if @map.id != @region
      @map = GameData::TownMap.get(@region)
      @sprites["map"].setBitmap("Graphics/UI/Town Map/#{@map.filename}")
      @sprites["map"].x = (Graphics.width - @sprites["map"].bitmap.width) / 2
      @sprites["map"].y = (Graphics.height - @sprites["map"].bitmap.height) / 2
      @sprites["mapbottom"].mapname = @map.name
      @sprites["player"].visible = false if @sprites["player"]
      @map_x = LEFT
      @map_y = TOP
    end
    @sprites["help"].bitmap.clear
    @sprites.each { |key, sprite| sprite.visible = false if key.start_with?("point") }
    result
  end

  def refresh_markers(players)
    active = []
    players.each_with_index do |(id, name), index|
      peer = id && AnilCoop.instance_variable_get(:@peers)[id]
      position = id ? peer && peer["position"] : nil
      map_id = id ? position && position["map"] : $game_map.map_id
      location = AnilCoop.online_map_position(map_id, position && position["x"], position && position["y"])
      next unless location && location[0] == @region
      key = "coop_marker_#{index}"
      marker = @sprites[key]
      unless marker
        marker = IconSprite.new(0, 0, @viewport)
        marker.setBitmap(GameData::TrainerType.player_map_icon_filename($player.trainer_type))
        marker.color = Color.new(40, 100, 255, 120) if id
        @sprites[key] = marker
      end
      marker.x = point_x_to_screen_x(location[1]) + (index % 2) * 10
      marker.y = point_y_to_screen_y(location[2]) + (index / 2) * 10
      marker.visible = true
      active << key
      if id == @selected_id
        @sprites["cursor"].x = point_x_to_screen_x(location[1])
        @sprites["cursor"].y = point_y_to_screen_y(location[2])
        @sprites["mapbottom"].maplocation = pbGetMapLocation(location[1], location[2])
        @sprites["mapbottom"].mapdetails = location[3]
      end
    end
    (@marker_ids - active).each { |key| @sprites[key].visible = false if @sprites[key] }
    @marker_ids = active
    selected_name = players.find { |entry| entry[0] == @selected_id }&.[](1) || "Jugador"
    selected_peer = @selected_id && AnilCoop.instance_variable_get(:@peers)[@selected_id]
    selected_map = @selected_id ? selected_peer&.dig("position", "map") : $game_map.map_id
    selected_location = AnilCoop.online_map_position(selected_map)
    @sprites["mapbottom"].mapname = "#{@map.name} — #{selected_name}"
    unless selected_location && selected_location[0] == @region
      @sprites["mapbottom"].maplocation = ""
      @sprites["mapbottom"].mapdetails = "Ubicación no disponible"
    end
  end

  def online_loop(players)
    loop do
      Graphics.update
      Input.update
      AnilCoop.tick($scene)
      pbUpdate
      players = AnilCoop.online_map_players
      refresh_markers(players)
      selected_peer = @selected_id && AnilCoop.instance_variable_get(:@peers)[@selected_id]
      selected_map = @selected_id ? selected_peer&.dig("position", "map") : $game_map.map_id
      selected_location = AnilCoop.online_map_position(selected_map)
      return :region_change if selected_location && selected_location[0] != @region
      if Input.trigger?(Input::BACK)
        pbPlayCloseMenuSE
        return :back
      end
      return :next if Input.trigger?(Input::RIGHT) && players.length > 1
      return :previous if Input.trigger?(Input::LEFT) && players.length > 1
    end
  end
end
