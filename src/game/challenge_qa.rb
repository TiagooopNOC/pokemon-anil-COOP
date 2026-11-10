# Opt-in isolated starter QA. Test saves use unique, non-player slot names.
require "digest"

module AnilCoopStarterQAMessages
  def pbMessage(*_args); 0; end
  def pbNickname(*_args); end
end

module AnilCoopChallengeQA
  def self.personal_save
    File.join(AnilCoopDev::SAVE_DIR, "Partida 1.rxdata")
  end

  def self.load_personal
    data = SaveData.get_data_from_file(personal_save)
    SaveData.load_bootup_values(data)
    Game.load(data)
  end

  def self.state
    { map: $game_map.map_id, party: $player.party.map { |pkmn| pkmn.species.to_s },
      random: RandomizedChallenge.enabled?, challenge_started: $PokemonGlobal.challenge_started,
      challenge_rules: $PokemonGlobal.challenge_rules&.map(&:to_s),
      challenge_encs_class: $PokemonGlobal.challenge_encs.class.to_s,
      challenge_encs_nil: $PokemonGlobal.challenge_encs.nil? }
  end

  def self.run(mode)
    before = Digest::SHA256.file(personal_save).hexdigest
    result = { mode: mode }
    case mode
    when "inspect", "regression"
      load_personal
      result[:before] = state
      if mode == "regression"
        raise "expected legacy QA ledger" unless $PokemonGlobal.challenge_encs.nil? &&
          ChallengeModes.rules.include?(:ONE_CAPTURE)
        # Reproduce the original plugin failure without a co-op connection or
        # Interpreter#execute_script wrapper; only the in-memory save is used.
        ChallengeModes.method(:begin_challenge).super_method.call
        original_error = nil
        begin
          ChallengeModes.method(:had_first_encounter?).super_method.call
        rescue NoMethodError => e
          original_error = e
        end
        raise "original plugin did not fail on nil ledger" unless original_error &&
          original_error.message.include?("[]")
        result[:original_without_coop] = original_error.class.to_s
        ChallengeModes.begin_challenge
        raise "challenge ledger not repaired" unless $PokemonGlobal.challenge_encs == {}
        raise "first encounter already marked" if ChallengeModes.had_first_encounter?
        result[:after] = state
        raise "random mode changed" unless result[:after][:random] &&
          result[:after][:challenge_rules] == result[:before][:challenge_rules]
        Object.prepend(AnilCoopStarterQAMessages)
        $map_factory.setup(29)
        $game_player.moveto(16, 11)
        lab_event = $game_map.events.fetch(28)
        interpreter = pbMapInterpreter
        interpreter.setup(lab_event.instance_variable_get(:@event).pages[1].list, 28)
        previous_party_size = $player.party.length
        raise "random starter gift failed" unless interpreter.execute_script("give_starter_random(0)")
        raise "random starter not added" unless $player.party.length == previous_party_size + 1
        raise "encounter not recorded" unless ChallengeModes.had_first_encounter?
        ChallengeModes.begin_challenge
        raise "encounter ledger reset" unless ChallengeModes.had_first_encounter?
        raise "event did not continue" unless interpreter.execute_script("$game_variables[902] = 77") == 77
        result[:lab_gift] = $player.party.last.species.to_s
        result[:lab_map] = $game_map.map_id
      end
    when "mixed", "new_normal", "new_random", "new_nuzlocke"
      Game.start_new
      randomized = mode == "new_random" || (mode == "mixed" && ENV["ANIL_COOP_NAME"] == "client04")
      RandomizedChallenge.enable if randomized
      if mode == "new_nuzlocke"
        $PokemonGlobal.challenge_rules = [:PERMAFAINT, :ONE_CAPTURE]
        $PokemonGlobal.challenge_encs = {} # Original ChallengeModes.start initialization.
        ChallengeModes.begin_challenge
      end
      $map_factory.setup(29)
      $game_player.moveto(16, 11)
      $scene.createSpritesets
      Graphics.transition(0)
      if mode == "mixed"
        deadline = System.uptime + 30
        until AnilCoop.connected? && AnilCoop.instance_variable_get(:@peers).length == 1
          Graphics.update
          AnilCoop.tick($scene)
          raise "mixed-mode peer timeout" if System.uptime > deadline
        end
      end
      Object.prepend(AnilCoopStarterQAMessages)
      lab_event = $game_map.events.fetch(28)
      interpreter = pbMapInterpreter
      interpreter.setup(lab_event.instance_variable_get(:@event).pages[1].list, 28)
      gift = randomized ? "give_starter_random(0)" : "pbAddPokemon(:BULBASAUR, 5)"
      raise "starter gift failed" unless interpreter.execute_script(gift)
      raise "starter missing" unless $player.party.length == 1
      raise "challenge encounter not recorded" if mode == "new_nuzlocke" &&
        !ChallengeModes.had_first_encounter?
      raise "event did not continue" unless interpreter.execute_script("$game_variables[902] = 77") == 77
      raise "script context leaked" unless AnilCoop.story_script_context.nil?
      raise "randomizer changed" unless RandomizedChallenge.enabled? == randomized
      result[:gift] = gift
      result[:after_gift] = state
      slot = "QA Starter #{mode} #{Time.now.to_i} #{Process.pid}"
      path = SaveData.get_full_path(slot)
      raise "QA save failed" unless Game.save(slot)
      result[:qa_save] = path
      result[:qa_save_hash] = Digest::SHA256.file(path).hexdigest
      if mode == "mixed"
        deadline = System.uptime + 2
        while System.uptime < deadline
          Graphics.update
          AnilCoop.tick($scene)
        end
        raise "mixed-mode connection lost" unless AnilCoop.connected?
      end
    when "reload"
      prior_mode = ENV.fetch("ANIL_COOP_CHALLENGE_PREVIOUS", "mixed")
      report = File.join(AnilCoopDev::PROFILE, "qa-challenge-#{prior_mode}.json")
      previous = JSON.parse(File.read(report))
      path = previous.fetch("qa_save")
      raise "QA save changed" unless Digest::SHA256.file(path).hexdigest == previous.fetch("qa_save_hash")
      data = SaveData.get_data_from_file(path)
      SaveData.load_bootup_values(data)
      Game.load(data)
      result[:reloaded] = state
      raise "starter not persisted" unless $player.party.length == 1
      raise "random mode not persisted" unless result[:reloaded][:random] == previous.fetch("after_gift").fetch("random")
      raise "challenge rules not persisted" unless result[:reloaded][:challenge_rules] == previous.fetch("after_gift").fetch("challenge_rules")
      raise "encounter ledger not persisted" unless result[:reloaded][:challenge_encs_class] ==
        previous.fetch("after_gift").fetch("challenge_encs_class")
    else
      raise "unknown starter QA mode"
    end
    raise "personal save changed" unless Digest::SHA256.file(personal_save).hexdigest == before
    result[:personal_save_unchanged] = true
    result[:pass] = true
    result
  end
end

$anil_coop_challenge_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :set_up_system && event.defined_class == Game.singleton_class
  $anil_coop_challenge_trace.disable
  mode = ENV.fetch("ANIL_COOP_CHALLENGE_QA")
  result = { mode: mode, pass: false }
  begin
    result = AnilCoopChallengeQA.run(mode)
  rescue StandardError => e
    result[:error] = "#{e.class}: #{e.message}"
    result[:trace] = e.backtrace.first(5)
  ensure
    File.write(File.join(AnilCoopDev::PROFILE, "qa-challenge-#{mode}.json"), JSON.generate(result))
    exit
  end
end
$anil_coop_challenge_trace.enable
