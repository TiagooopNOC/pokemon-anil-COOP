# Produces a complete candidate save in the isolated profile. The active save,
# live party and game state remain unchanged until a durable commit decision.
require "digest"

class PokemonGlobalMetadata
  attr_accessor :anil_coop_trade_receipts
end

module AnilCoopTradeCandidate
  def self.create(txid, slot, outgoing_data, incoming_data)
    raise "Identificador de intercambio inválido" unless txid.is_a?(String) && txid.match?(/\A[0-9a-f]{32}\z/)
    raise "Partida no cargada" unless $player && $PokemonGlobal && $player.save_slot
    raise "Posición de equipo inválida" unless slot.is_a?(Integer) && slot.between?(0, $player.party.length - 1)
    original = $player.party[slot]
    raise "Pokémon propio no intercambiable" unless AnilCoop.trade_eligible?(original)
    raise "La oferta propia cambió" unless AnilCoopTradeData.pack(original) == outgoing_data
    incoming = AnilCoopTradeData.unpack(incoming_data)
    raise "Pokémon recibido no intercambiable" unless AnilCoop.trade_eligible?(incoming)
    own_key = [original.owner.id, original.personalID]
    incoming_key = [incoming.owner.id, incoming.personalID]
    raise "Identidad repetida" if own_key == incoming_key || $player.party.each_with_index.any? { |p, i|
      i != slot && [p.owner.id, p.personalID] == incoming_key }

    save_path = File.expand_path(SaveData.get_full_path($player.save_slot))
    save_dir = File.realpath(AnilCoopDev::SAVE_DIR)
    raise "Guardado fuera del perfil aislado" unless File.dirname(save_path) == save_dir &&
      File.file?(save_path) && !File.symlink?(save_path)
    before_hash = Digest::SHA256.file(save_path).hexdigest
    name = "trade-#{txid}.rxdata.tmp"
    candidate = File.join(save_dir, name)
    receipts = $PokemonGlobal.anil_coop_trade_receipts
    raise "Registro de intercambios incompatible" unless receipts.nil? || receipts.is_a?(Hash)
    raise "Intercambio ya registrado" if receipts && receipts.key?(txid)
    receipt = { "slot" => slot, "gave" => own_key, "received" => incoming_key,
                "before" => before_hash }
    old_party = $player.party
    old_receipts = receipts
    receipt_defined = $PokemonGlobal.instance_variable_defined?(:@anil_coop_trade_receipts)
    begin
      $player.party = old_party.dup
      $player.party[slot] = incoming
      $PokemonGlobal.anil_coop_trade_receipts = (receipts || {}).merge(txid => receipt)
      save_data = SaveData.compile_save_hash
      File.open(candidate, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
        candidate_created = true
        Marshal.dump(save_data, file) # Trusted local game objects; never network input.
        file.flush
        file.fsync
      end
    ensure
      $player.party = old_party
      if receipt_defined
        $PokemonGlobal.anil_coop_trade_receipts = old_receipts
      elsif $PokemonGlobal.instance_variable_defined?(:@anil_coop_trade_receipts)
        $PokemonGlobal.remove_instance_variable(:@anil_coop_trade_receipts)
      end
    end
    loaded = SaveData.get_data_from_file(candidate)
    raise "Candidato incompleto" unless loaded.is_a?(Hash) &&
      loaded[:global_metadata].anil_coop_trade_receipts[txid] == receipt &&
      AnilCoopTradeData.pack(loaded[:player].party[slot]) == incoming_data
    raise "El guardado original cambió" unless Digest::SHA256.file(save_path).hexdigest == before_hash
    { "save_name" => File.basename(save_path), "candidate_name" => name,
      "before_hash" => before_hash, "after_hash" => Digest::SHA256.file(candidate).hexdigest }
  rescue Exception
    # A failed candidate cannot be mistaken for a prepared trade. A valid
    # prepared candidate is kept after this method returns and escrow records it.
    File.delete(candidate) if candidate_created && candidate && File.file?(candidate)
    raise
  end
end
