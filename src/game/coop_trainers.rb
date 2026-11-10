# Local trainer identity and native enemy generation; no campaign state on the server.
class PokemonGlobalMetadata
  attr_accessor :anil_coop_trainers
end

module AnilCoop
  class << self
    attr_accessor :story_script_context
  end

  STORY_RULES = %w[canLose outcomeVar midbattleScript backdrop base battleBGM
                   victoryBGM lowHealthBGM environment defaultWeather
                   defaultTerrain battleAnims].freeze

  def self.trainer_call_label(event, args)
    page = if event
      source = event.instance_variable_get(:@event)
      source&.pages&.index(event.instance_variable_get(:@page))
    end
    safe_args = args.map do |arg|
      case arg
      when Symbol, Integer then arg.to_s
      when String then arg.gsub(/[\r\n\t]/, " ")[0, 40]
      else arg.class.to_s
      end
    end
    "map=#{event&.map_id || $game_map&.map_id} event=#{event&.id || 0} page=#{page || '-'} args=#{safe_args.inspect}"
  end

  def self.story_trainer_compatible?(event, args)
    context = @story_script_context
    return "script_context_missing" unless context
    script = context[:script]
    return "script_not_direct" unless script.is_a?(String) &&
      script.scan(/\bTrainerBattle\.start\s*\(/).length == 1
    interpreter = context[:interpreter]
    return "script_event_mismatch" unless event && interpreter.get_self.equal?(event) &&
      interpreter.instance_variable_get(:@map_id) == event.map_id
    source = event.instance_variable_get(:@event)
    return "event_page_missing" unless source && source.pages.include?(event.instance_variable_get(:@page))
    begin
      trainer_identity(event, args)
    rescue StandardError
      return "unsupported_trainer_arguments"
    end
    rules = $game_temp.battle_rules.keys.map(&:to_s) - STORY_RULES
    return "unsupported_rules:#{rules.sort.join(',')}" unless rules.empty?
    nil
  end

  # The first Gary battle is a conditional script on page 1 of Map029/event 3,
  # after Oak's cutscene. Keep the original interpreter before and after it.
  def self.first_gary_event?(event, args)
    return false unless event.map_id == 29 && event.id == 3 &&
      args.length == 3 && args[0] == :AZUL1 && args[1] == "Azul" && (1..3).include?(args[2])
    source = event.instance_variable_get(:@event)
    page = event.instance_variable_get(:@page)
    return false unless source && source.pages[1].equal?(page)
    page.list.any? do |command|
      command.code == 111 && command.parameters[0] == 12 &&
        command.parameters[1] == "TrainerBattle.start(:AZUL1, \"Azul\", #{args[2]})"
    end
  end

  def self.trainer_identity(event, args)
    normalize = lambda do |value|
      case value
      when Symbol then value.to_s
      when String, Integer then value
      when Array then value.map { |v| normalize.call(v) }
      else raise "Este encuentro especial todavía requiere combate individual."
      end
    end
    pages = event.instance_variable_get(:@event).pages
    page = pages.index(event.instance_variable_get(:@page)) || 0
    Digest::SHA256.hexdigest(JSON.generate([event.map_id, event.id, page, normalize.call(args)]))
  end

  def self.trainer_completed?(identity)
    !!($PokemonGlobal.anil_coop_trainers || {})[identity]
  end

  def self.send_trainer_foe(event, args)
    if @pending_foe
      trainer_send("trainer_foe", event, @pending_foe)
      return
    end
    trainers, items, party, starts = TrainerBattle.generate_foes(*args)
    raise "Este entrenador requiere un combate individual." unless trainers.length == 1 &&
      party.length.between?(1, 6) && starts == [0] && items.length == 1
    inventory = items[0].map(&:to_s)
    raise "Objetos de entrenador todavía no compatibles." unless inventory.length <= 4 &&
      inventory.all? { |item| ["POTION", "SUPERPOTION"].include?(item) }
    trainer = trainers[0]
    data = { "id" => trainer.id, "name" => trainer.name, "gender" => trainer.gender || 2,
      "language" => trainer.language, "trainer_type" => trainer.trainer_type.to_s,
      "lose_text" => trainer.lose_text.to_s, "win_text" => trainer.win_text.to_s,
      "items" => inventory }
    @pending_foe = { team: party.each_with_index.map { |p, i| team_snapshot(p, i) }, trainer: data }
    trainer_send("trainer_foe", event, @pending_foe)
  end
end

# Captures the event script that actually called TrainerBattle.start, including
# conditional commands and child interpreters from common events. The original
# interpreter continues unchanged after the co-op result is returned.
module AnilCoopStoryInterpreter
  def execute_script(script)
    previous = AnilCoop.story_script_context
    AnilCoop.story_script_context = { interpreter: self, script: script }
    super
  ensure
    AnilCoop.story_script_context = previous
  end
end
Interpreter.prepend(AnilCoopStoryInterpreter)
