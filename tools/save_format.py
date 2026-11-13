"""Read the structure of a Ruby Marshal save without constructing Ruby objects."""
from collections import Counter

from .h0 import SafetyError


MAX_SAVE_SIZE = 32 * 1024 * 1024
EXPECTED_VERSIONS = {b"essentials_version": b"21.1", b"game_version": b"4.1.1"}
CORE_OBJECTS = {
    b"player": b"Player",
    b"game_system": b"Game_System",
    b"pokemon_system": b"PokemonSystem",
    b"game_player": b"Game_Player",
    b"global_metadata": b"PokemonGlobalMetadata",
    b"map_factory": b"PokemonMapFactory",
    b"bag": b"PokemonBag",
    b"storage_system": b"PokemonStorage",
}
INVALID = "El archivo no es una partida válida de Pokémon Añil."


class MarshalReader:
    def __init__(self, data):
        self.data = data
        self.offset = 0
        self.symbols = []
        self.objects = 0
        self.budget = 500_000

    def take(self, size):
        end = self.offset + size
        if size < 0 or end > len(self.data):
            raise SafetyError(INVALID)
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def integer(self):
        lead = int.from_bytes(self.take(1), "little", signed=True)
        if -4 <= lead <= 4:
            return int.from_bytes(self.take(abs(lead)), "little", signed=False) - (
                1 << (-lead * 8) if lead < 0 else 0)
        return lead - 5 if lead > 0 else lead + 5

    def count(self):
        count = self.integer()
        if not 0 <= count <= len(self.data) - self.offset:
            raise SafetyError(INVALID)
        return count

    def symbol(self, tag):
        if tag == b":":
            symbol = self.take(self.count())
            self.symbols.append(symbol)
            return symbol
        if tag == b";":
            index = self.integer()
            if 0 <= index < len(self.symbols):
                return self.symbols[index]
        raise SafetyError(INVALID)

    def pairs(self, depth):
        for _ in range(self.count()):
            yield self.node(depth + 1), self.node(depth + 1)

    def node(self, depth=0):
        self.budget -= 1
        if depth > 180 or self.budget < 0:
            raise SafetyError(INVALID)
        tag = self.take(1)
        if tag in (b":", b";"):
            return "symbol", self.symbol(tag)
        if tag == b"I":
            value = self.node(depth + 1)
            for key, _ in self.pairs(depth):
                if key[0] != "symbol":
                    raise SafetyError(INVALID)
            return value
        if tag == b"@":
            index = self.integer()
            if not 0 <= index < self.objects:
                raise SafetyError(INVALID)
            return "reference", None
        if tag in (b"0", b"T", b"F"):
            return "literal", None
        if tag == b"i":
            self.integer()
            return "integer", None
        self.objects += 1
        if tag in (b'"', b"f"):
            value = self.take(self.count())
            return ("string", value) if tag == b'"' else ("float", None)
        if tag == b"l":
            if self.take(1) not in (b"+", b"-"):
                raise SafetyError(INVALID)
            self.take(self.count() * 2)
        elif tag == b"[":
            for _ in range(self.count()):
                self.node(depth + 1)
        elif tag in (b"{", b"}"):
            metadata = {}
            for key, value in self.pairs(depth):
                if depth == 0:
                    if key[0] != "symbol" or key[1] in metadata:
                        raise SafetyError(INVALID)
                    metadata[key[1]] = value
            if tag == b"}":
                self.node(depth + 1)
            return "hash", metadata
        elif tag in (b"o", b"S", b"u"):
            name = self.symbol(self.take(1))
            if tag == b"u":
                # Built-in serializers used by Essentials/mkxp. Their bytes stay opaque.
                if name not in (b"Time", b"Table", b"Tone", b"Color", b"Rect"):
                    raise SafetyError(INVALID)
                self.take(self.count())
            else:
                for key, _ in self.pairs(depth):
                    if key[0] != "symbol":
                        raise SafetyError(INVALID)
            return "object", name
        else:
            raise SafetyError(INVALID)
        return "value", None


def validate_save(data):
    if not data.startswith(b"\x04\x08{"):
        raise SafetyError(INVALID)
    reader = MarshalReader(data)
    reader.take(2)
    _, metadata = reader.node()
    if reader.offset != len(data) or any(
        metadata.get(key) != ("object", name) for key, name in CORE_OBJECTS.items()
    ):
        raise SafetyError(INVALID)
    if any(metadata.get(key) != ("string", value) for key, value in EXPECTED_VERSIONS.items()):
        raise SafetyError("Esta partida debe ser de Añil v4.14 (Essentials 21.1, formato 4.1.1).")
