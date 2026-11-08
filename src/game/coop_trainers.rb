# Local trainer identity and native enemy generation; no campaign state on the server.
class PokemonGlobalMetadata
  attr_accessor :anil_coop_trainers
end

module AnilCoop
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
      party.length.between?(1, 6) && starts == [0] && items.all?(&:empty?)
    trainer = trainers[0]
    data = { "id" => trainer.id, "name" => trainer.name, "gender" => trainer.gender || 2,
      "language" => trainer.language, "trainer_type" => trainer.trainer_type.to_s,
      "lose_text" => trainer.lose_text.to_s, "win_text" => trainer.win_text.to_s }
    @pending_foe = { team: party.each_with_index.map { |p, i| team_snapshot(p, i) }, trainer: data }
    trainer_send("trainer_foe", event, @pending_foe)
  end
end
