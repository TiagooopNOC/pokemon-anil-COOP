# Repair legacy isolated challenge profiles whose encounter ledger was never
# initialized. The original ChallengeModes.start sets this hash; begin_challenge
# does not, and older QA provisioning called begin_challenge directly.
module AnilCoopChallengeLedger
  def ensure_encounter_ledger
    return unless $PokemonGlobal &&
      (ChallengeModes.rules.include?(:FIRST_CAPTURE) || ChallengeModes.rules.include?(:ONE_CAPTURE))
    return if $PokemonGlobal.challenge_encs.is_a?(Hash)
    raise "Registro de encuentros de desafío incompatible" unless $PokemonGlobal.challenge_encs.nil?
    $PokemonGlobal.challenge_encs = {}
    AnilCoop.log("challenge encounter ledger initialized for active capture rule")
  end

  def begin_challenge
    ensure_encounter_ledger
    super
  end

  def had_first_encounter?(*args)
    ensure_encounter_ledger if ChallengeModes.on?(:FIRST_CAPTURE) || ChallengeModes.on?(:ONE_CAPTURE)
    super
  end

  def set_first_encounter(*args)
    ensure_encounter_ledger if ChallengeModes.on?(:FIRST_CAPTURE) || ChallengeModes.on?(:ONE_CAPTURE)
    super
  end
end
ChallengeModes.singleton_class.prepend(AnilCoopChallengeLedger)
