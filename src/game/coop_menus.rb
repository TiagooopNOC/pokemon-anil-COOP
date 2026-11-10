# Native party/summary sub-scenes have their own update loops, outside Battle::Scene.
module AnilCoop
  def self.track_battle_menu(scene)
    (@battle_menus ||= []) << scene if coop_battle_active?
  end

  def self.untrack_battle_menu(scene)
    @battle_menus&.delete(scene)
  end

  def self.update_battle_menu
    if @team_menu_active
      battle_tick
      return
    end
    return unless coop_battle_active?
    battle_tick
    check_battle_transport!
  end

  def self.close_battle_menus
    # A transport exception unwinds native loops before their ordinary EndScene.
    # Dispose nested summary before its party scene, even after a partial start.
    Array(@battle_menus).dup.reverse_each do |scene|
      untrack_battle_menu(scene)
      begin
        scene.pbEndScene
      rescue StandardError => e
        log("menu cleanup #{scene.class}: #{e.message}")
      end
    end
  end
end

module AnilCoopMenuLifecycle
  def pbStartScene(*args, **kwargs)
    AnilCoop.track_battle_menu(self)
    super
  end

  def pbEndScene
    AnilCoop.untrack_battle_menu(self)
    super
  end
end

module AnilCoopPartyHeartbeat
  def update
    super
    AnilCoop.update_battle_menu
  end
end

module AnilCoopSummaryHeartbeat
  def pbUpdate
    super
    AnilCoop.update_battle_menu
  end
end

PokemonParty_Scene.prepend(AnilCoopMenuLifecycle)
PokemonParty_Scene.prepend(AnilCoopPartyHeartbeat)
PokemonSummary_Scene.prepend(AnilCoopMenuLifecycle)
PokemonSummary_Scene.prepend(AnilCoopSummaryHeartbeat)
