# Shared turbo control. Añil's original Q handler remains the input source.
module AnilCoop
  def self.speed_host?
    connected? && @speed_host == @id
  end

  def self.speed_active?
    connected? && !!@speed_active
  end

  def self.speed_set(level, cooperative:)
    return unless (0..2).include?(level) && defined?(SPEEDUP_STAGES) && System.respond_to?(:real_uptime)
    @native_third_speed ||= SPEEDUP_STAGES[2]
    multiplier = cooperative ? 3.0 : @native_third_speed
    return if $GameSpeed == level && SPEEDUP_STAGES[2] == multiplier
    before = System.uptime
    SPEEDUP_STAGES[2] = multiplier
    $GameSpeed = level
    $SpeedDiference = before - SPEEDUP_STAGES[level] * System.real_uptime
    $buttonframes = 0
    $RefreshEventsForTurbo = true
    log("shared speed #{SPEEDUP_STAGES[level]} stage=#{level} battle=#{!!@speed_battle_lock}")
  end

  def self.speed_receive(message)
    host, level, active = message.values_at("host", "speed", "speed_active")
    return unless host.is_a?(String) && type_speed?(level) && (active == true || active == false)
    @speed_host, @shared_speed, @speed_active = host, level, active
    if @speed_battle_lock
      speed_set(0, cooperative: active)
    elsif active
      speed_set(level, cooperative: true)
    else
      speed_set($GameSpeed, cooperative: false)
    end
    $CanToggle = !@speed_battle_lock && (active ? speed_host? : speed_native_toggle?)
    speed_indicator_update
  end

  def self.type_speed?(value)
    value.is_a?(Integer) && (0..2).include?(value)
  end

  def self.speed_native_toggle?
    !$PokemonSystem || $PokemonSystem.only_speedup_battles == 0 ||
      ($game_temp && $game_temp.in_battle)
  end

  def self.speed_welcome
    queue(type: "speed_set", speed: $GameSpeed) if speed_host?
  end

  def self.speed_after_input(old_level, old_time)
    if @speed_battle_lock
      speed_set(0, cooperative: speed_active?)
      $CanToggle = false
    elsif speed_active?
      if speed_host?
        if $GameSpeed != old_level
          # Añil changes $GameSpeed directly. Preserve its timer continuity.
          $SpeedDiference = old_time - SPEEDUP_STAGES[$GameSpeed] * System.real_uptime
          @shared_speed = $GameSpeed
          queue(type: "speed_set", speed: $GameSpeed)
          log("host requested shared speed stage=#{$GameSpeed}")
        end
      else
        speed_set(@shared_speed, cooperative: true)
      end
      $CanToggle = speed_host?
    elsif speed_host? && $GameSpeed != old_level
      queue(type: "speed_set", speed: $GameSpeed)
    end
  end

  def self.speed_battle_enter
    @speed_battle_lock = true
    speed_set(0, cooperative: speed_active?)
    $CanToggle = false
  end

  def self.speed_battle_enforce
    return unless @speed_battle_lock
    speed_set(0, cooperative: speed_active?)
    $CanToggle = false
  end

  def self.speed_battle_exit
    @speed_battle_lock = false
    if speed_active?
      speed_set(@shared_speed, cooperative: true)
      $CanToggle = speed_host?
    else
      speed_set($GameSpeed, cooperative: false)
      $CanToggle = speed_native_toggle?
    end
  end

  def self.speed_disconnect
    @speed_battle_lock = false
    @speed_active = false
    @speed_host = nil
    speed_set($GameSpeed, cooperative: false)
    $CanToggle = speed_native_toggle?
    speed_indicator_clear
  end

  def self.speed_indicator_update
    unless speed_active? || (connected? && @speed_battle_lock)
      speed_indicator_clear
      return
    end
    level = @speed_battle_lock ? 0 : @shared_speed
    return if @speed_indicator && !@speed_indicator.disposed? && @speed_indicator_level == level
    speed_indicator_clear
    bitmap = Bitmap.new(48, 22)
    bitmap.fill_rect(0, 0, 48, 22, Color.new(0, 0, 0, 150))
    bitmap.font.size = 16
    bitmap.font.color = Color.new(255, 255, 255)
    bitmap.draw_text(0, 0, 48, 22, "×#{level + 1}", 1)
    @speed_indicator = Sprite.new
    @speed_indicator.bitmap = bitmap
    @speed_indicator.x = Graphics.width - 52
    @speed_indicator.y = 4
    @speed_indicator.z = 999998
    @speed_indicator_level = level
  end

  def self.speed_indicator_clear
    if @speed_indicator && !@speed_indicator.disposed?
      @speed_indicator.bitmap&.dispose
      @speed_indicator.dispose
    end
    @speed_indicator = @speed_indicator_level = nil
  end
end

module AnilCoopSharedSpeedInput
  def update
    old_level = $GameSpeed
    old_time = System.uptime
    $CanToggle = false if (AnilCoop.speed_active? && !AnilCoop.speed_host?) ||
                          AnilCoop.instance_variable_get(:@speed_battle_lock)
    super
    AnilCoop.speed_after_input(old_level, old_time)
  end
end

module AnilCoopSharedSpeedGraphics
  def update
    super
    AnilCoop.speed_indicator_update
  end
end

Input.singleton_class.prepend(AnilCoopSharedSpeedInput)
Graphics.singleton_class.prepend(AnilCoopSharedSpeedGraphics)
