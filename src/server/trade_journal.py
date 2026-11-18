"""Durable decision ledger for two-player trades.

SQLite commits are synchronized before this API reports a decision. The two
clients must still persist their own prepared records and apply atomically.
This component alone does not make a distributed trade safe.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import os
import re
import sqlite3
from pathlib import Path

HEX32 = re.compile(r"[0-9a-f]{32}\Z")
MAX_OFFER_BYTES = 65_536


class TradeJournal:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                pass
            else:
                os.close(fd)
        # State.lock serializes access from the threaded session server.
        self.db = sqlite3.connect(self.path, isolation_level=None, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=DELETE")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("""CREATE TABLE IF NOT EXISTS trades (
            txid TEXT PRIMARY KEY,
            first_player TEXT NOT NULL,
            second_player TEXT NOT NULL,
            first_offer TEXT NOT NULL,
            second_offer TEXT NOT NULL,
            first_digest TEXT NOT NULL,
            second_digest TEXT NOT NULL,
            first_prepared INTEGER NOT NULL DEFAULT 0,
            second_prepared INTEGER NOT NULL DEFAULT 0,
            decision TEXT,
            first_applied INTEGER NOT NULL DEFAULT 0,
            second_applied INTEGER NOT NULL DEFAULT 0
        )""")

    def close(self):
        self.db.close()

    @contextmanager
    def _atomic(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    @staticmethod
    def _offer(value):
        if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("pokemon"), dict):
            raise ValueError("invalid versioned offer")
        encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        if len(encoded.encode("utf-8")) > MAX_OFFER_BYTES:
            raise ValueError("offer too large")
        return encoded, hashlib.sha256(encoded.encode("utf-8")).hexdigest()

    @staticmethod
    def _ids(txid, players):
        if not isinstance(txid, str) or not HEX32.fullmatch(txid):
            raise ValueError("invalid transaction id")
        if not isinstance(players, (list, tuple)) or len(players) != 2 or players[0] == players[1] or any(
            not isinstance(p, str) or not HEX32.fullmatch(p) for p in players
        ):
            raise ValueError("invalid stable player ids")

    def store_offers(self, txid: str, players: tuple[str, str], offers: tuple[dict, dict]):
        """Store a complete, immutable pair before asking either side to prepare."""
        self._ids(txid, players)
        if not isinstance(offers, (list, tuple)) or len(offers) != 2:
            raise ValueError("expected two offers")
        first, first_hash = self._offer(offers[0])
        second, second_hash = self._offer(offers[1])
        with self._atomic():
            self.db.execute("""INSERT OR IGNORE INTO trades
                (txid, first_player, second_player, first_offer, second_offer, first_digest, second_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (txid, *players, first, second, first_hash, second_hash))
            row = self.db.execute("""SELECT first_player, second_player, first_offer, second_offer
                FROM trades WHERE txid=?""", (txid,)).fetchone()
            if row != (*players, first, second):
                raise ValueError("transaction offers are immutable")

    def get(self, txid: str):
        if not isinstance(txid, str) or not HEX32.fullmatch(txid):
            raise ValueError("invalid transaction id")
        row = self.db.execute("SELECT * FROM trades WHERE txid=?", (txid,)).fetchone()
        if row is None:
            return None
        return {"txid": row[0], "players": (row[1], row[2]),
                "offers": (json.loads(row[3]), json.loads(row[4])),
                "digests": (row[5], row[6]), "prepared": (bool(row[7]), bool(row[8])),
                "decision": row[9], "applied": (bool(row[10]), bool(row[11]))}

    def _index(self, record, player):
        if record is None or player not in record["players"]:
            raise ValueError("player is not in transaction")
        return record["players"].index(player)

    def mark_prepared(self, txid: str, player: str, own_digest: str, incoming_digest: str):
        """Accept a receipt only for the immutable offers this client prepared."""
        with self._atomic():
            record = self.get(txid)
            index = self._index(record, player)
            if record["decision"] or own_digest != record["digests"][index] or incoming_digest != record["digests"][1-index]:
                raise ValueError("invalid prepared receipt")
            column = "first_prepared" if index == 0 else "second_prepared"
            self.db.execute(f"UPDATE trades SET {column}=1 WHERE txid=?", (txid,))

    def decide_commit(self, txid: str):
        """The commit point. A caller must not send a commit before return."""
        with self._atomic():
            record = self.get(txid)
            if record is None or record["prepared"] != (True, True):
                raise ValueError("both clients must prepare first")
            if record["decision"] not in (None, "commit"):
                raise ValueError("conflicting decision")
            self.db.execute("UPDATE trades SET decision='commit' WHERE txid=?", (txid,))
        return "commit"

    def decide_abort(self, txid: str):
        """Abort only before the irreversible commit point."""
        with self._atomic():
            record = self.get(txid)
            if record is None or record["decision"] not in (None, "abort"):
                raise ValueError("cannot reverse a committed transaction")
            self.db.execute("UPDATE trades SET decision='abort' WHERE txid=?", (txid,))
        return "abort"

    def mark_applied(self, txid: str, player: str):
        with self._atomic():
            record = self.get(txid)
            index = self._index(record, player)
            if record["decision"] != "commit":
                raise ValueError("no durable commit decision")
            column = "first_applied" if index == 0 else "second_applied"
            self.db.execute(f"UPDATE trades SET {column}=1 WHERE txid=?", (txid,))

    def mark_aborted(self, txid: str, player: str):
        with self._atomic():
            record = self.get(txid)
            index = self._index(record, player)
            if record["decision"] != "abort":
                raise ValueError("no durable abort decision")
            column = "first_applied" if index == 0 else "second_applied"
            self.db.execute(f"UPDATE trades SET {column}=1 WHERE txid=?", (txid,))

    def pending_for(self, player: str):
        if not isinstance(player, str) or not HEX32.fullmatch(player):
            raise ValueError("invalid stable player id")
        rows = self.db.execute("""SELECT txid FROM trades WHERE
            (first_player=? OR second_player=?) AND (first_applied=0 OR second_applied=0)
            ORDER BY rowid""", (player, player)).fetchall()
        return [self.get(row[0]) for row in rows]
