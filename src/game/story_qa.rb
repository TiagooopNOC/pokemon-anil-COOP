# Opt-in read-only inspection of original events in an isolated game copy.
require "digest"
$anil_coop_story_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_story_trace.disable
  result = { maps: [] }
  begin
    [29, 5, 15].each do |map_id|
      map = load_data(sprintf("Data/Map%03d.rxdata", map_id))
      chosen = map.events.values.filter_map do |ev|
        pages = ev.pages.each_with_index.filter_map do |page, index|
          next unless page.list.any? { |cmd|
            cmd.parameters.any? { |value| value.is_a?(String) && value.include?("TrainerBattle.start") }
          }
          commands = page.list.each_with_index.map do |cmd, i|
            values = cmd.parameters.map do |p|
              p.is_a?(String) ? p.encode("UTF-8", invalid: :replace, undef: :replace) : p.inspect
            end
            { index: i, code: cmd.code, indent: cmd.indent, params: values }
          end
          { page: index, trigger: page.trigger, commands: commands }
        end
        next if pages.empty?
        { id: ev.id, name: ev.name, x: ev.x, y: ev.y, pages: pages }
      end
      result[:maps] << { map: map_id, events: chosen }
    end
    save = File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
    before = Digest::SHA256.file(save).hexdigest
    data = SaveData.get_data_from_file(save)
    SaveData.load_bootup_values(data)
    Game.load(data)
    map = $map_factory.getMapNoAdd(29)
    gary = map.events.fetch(3)
    source = gary.instance_variable_get(:@event)
    gary.instance_variable_set(:@page, source.pages[1])
    result[:first_gary] = (1..3).map do |version|
      args = [:AZUL1, "Azul", version]
      trainers, items, party, starts = TrainerBattle.generate_foes(*args)
      { version: version, recognized: AnilCoop.first_gary_event?(gary, args),
        trainer_count: trainers.length, species: party.map { |p| p.species.to_s },
        moves: party.map { |p| p.moves.map { |m| m.id.to_s } },
        items: items.map { |list| list.map(&:to_s) }, starts: starts }
    end
    result[:midbattle_script] = MidbattleHandlers.exists?(:midbattle_scripts, :azul_combate_inicial)
    result[:save_unchanged] = Digest::SHA256.file(save).hexdigest == before
  rescue StandardError => e
    result[:error] = "#{e.class}: #{e.message}"
    result[:trace] = e.backtrace.first(5)
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-story-events.json"), JSON.generate(result))
    exit
  end
end
$anil_coop_story_trace.enable
