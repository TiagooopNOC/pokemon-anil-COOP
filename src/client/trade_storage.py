"""Local trade escrow for isolated saves.

The game produces a complete candidate save in the same directory as the
original. This helper records its hashes before the server's commit decision,
then uses os.replace to install it. An interrupted replacement is recognized
by the candidate's hash on the destination. The database never stores game
objects and the normal save path is untouched until commit.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import sqlite3

HEX32 = re.compile(r"[0-9a-f]{32}\Z")
SAVE_NAME = re.compile(r"(?:Partida [1-9][0-9]*|Auto [1-3])\.rxdata\Z")
MAX_SAVE_BYTES = 32 * 1024 * 1024


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            sha.update(chunk)
    return sha.hexdigest()


class TradeStorage:
    def __init__(self, save_dir: Path):
        self.save_dir = Path(save_dir).resolve(strict=True)
        if not self.save_dir.is_dir():
            raise ValueError("missing isolated save directory")
        self.path = self.save_dir.parent / "trade-escrow.sqlite3"
        self.lock_path = self.save_dir.parent / "trade-pending.lock"
        if not self.path.exists():
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                pass
            else:
                os.close(fd)
        # The loopback helper handles both game and recovery requests in worker
        # threads. Its caller serializes access with a lock.
        self.db = sqlite3.connect(self.path, isolation_level=None, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=DELETE")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS escrow (
            txid TEXT PRIMARY KEY,
            save_name TEXT NOT NULL,
            candidate_name TEXT NOT NULL,
            before_hash TEXT NOT NULL,
            after_hash TEXT NOT NULL,
            decision TEXT,
            applied INTEGER NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0,
            session_host TEXT,
            session_code TEXT,
            session_mode TEXT
        )""")
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(escrow)")}
        for name, kind in (("completed", "INTEGER NOT NULL DEFAULT 0"),
                           ("session_host", "TEXT"), ("session_code", "TEXT"),
                           ("session_mode", "TEXT")):
            if name not in columns:
                self.db.execute(f"ALTER TABLE escrow ADD COLUMN {name} {kind}")

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
    def _txid(value):
        if not isinstance(value, str) or not HEX32.fullmatch(value):
            raise ValueError("invalid transaction id")

    def _file(self, name):
        path = self.save_dir / name
        if path.is_symlink() or path.parent.resolve() != self.save_dir:
            raise ValueError("save path escaped isolated profile")
        return path

    def get(self, txid):
        self._txid(txid)
        row = self.db.execute("SELECT * FROM escrow WHERE txid=?", (txid,)).fetchone()
        if not row:
            return None
        return {"txid": row[0], "save_name": row[1], "candidate_name": row[2],
                "before_hash": row[3], "after_hash": row[4],
                "decision": row[5], "applied": bool(row[6]), "completed": bool(row[7]),
                "session_host": row[8], "session_code": row[9], "session_mode": row[10]}

    def pending(self):
        rows = self.db.execute("SELECT txid FROM escrow WHERE completed=0 AND decision IS NOT 'abort'").fetchall()
        return [self.get(row[0]) for row in rows]

    def _lock(self, txid):
        if self.lock_path.exists():
            if self.lock_path.read_text(encoding="ascii") != txid:
                raise ValueError("another trade blocks this profile")
            return
        try:
            fd = os.open(self.lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            raise ValueError("another trade blocks this profile")
        try:
            os.write(fd, txid.encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)

    def _unlock(self, txid):
        if self.lock_path.exists():
            if self.lock_path.read_text(encoding="ascii") != txid:
                raise ValueError("trade lock belongs to another transaction")
            self.lock_path.unlink()

    def prepare(self, txid, save_name, candidate_name, before_hash, session=None):
        self._txid(txid)
        if not isinstance(save_name, str) or not SAVE_NAME.fullmatch(save_name):
            raise ValueError("invalid save slot")
        if candidate_name != f"trade-{txid}.rxdata.tmp":
            raise ValueError("invalid candidate filename")
        if not isinstance(before_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", before_hash):
            raise ValueError("invalid original digest")
        session = session or {}
        if session and (session.get("mode") not in ("create", "join") or
                        not isinstance(session.get("host"), str) or
                        not isinstance(session.get("code"), str) or
                        not re.fullmatch(r"[A-Z0-9]{12}", session["code"])):
            raise ValueError("invalid recovery session")
        original, candidate = self._file(save_name), self._file(candidate_name)
        if not original.is_file() or not candidate.is_file() or candidate.stat().st_size > MAX_SAVE_BYTES:
            raise ValueError("missing or oversized save")
        if digest(original) != before_hash:
            raise ValueError("original save changed during preparation")
        after_hash = digest(candidate)
        if after_hash == before_hash:
            raise ValueError("candidate did not change save")
        if any(record["txid"] != txid for record in self.pending()):
            raise ValueError("another trade blocks this profile")
        # Candidate bytes were written by Ruby with flush/fsync before this call.
        # Reopen and fsync here as an independent durability check.
        with candidate.open("rb") as stream:
            os.fsync(stream.fileno())
        self._lock(txid)  # Before durable receipt: a crash must block game startup.
        with self._atomic():
            self.db.execute("""INSERT OR IGNORE INTO escrow
                (txid, save_name, candidate_name, before_hash, after_hash,
                 session_host, session_code, session_mode)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (txid, save_name, candidate_name, before_hash, after_hash,
                 session.get("host"), session.get("code"), session.get("mode")))
            record = self.get(txid)
            if record is None or any(record[k] != value for k, value in (
                ("save_name", save_name), ("candidate_name", candidate_name),
                ("before_hash", before_hash), ("after_hash", after_hash),
                ("session_host", session.get("host")), ("session_code", session.get("code")),
                ("session_mode", session.get("mode"))
            )):
                raise ValueError("prepared candidate is immutable")
        return after_hash

    def decide(self, txid, decision):
        if decision not in ("commit", "abort"):
            raise ValueError("invalid decision")
        with self._atomic():
            record = self.get(txid)
            if record is None or record["decision"] not in (None, decision):
                raise ValueError("missing or conflicting decision")
            if record["applied"] and decision != "commit":
                raise ValueError("cannot abort an applied trade")
            self.db.execute("UPDATE escrow SET decision=? WHERE txid=?", (decision, txid))
        if decision == "abort":
            self.finish_abort(txid)

    def finish_abort(self, txid):
        record = self.get(txid)
        if record is None or record["decision"] != "abort" or record["applied"]:
            raise ValueError("no durable abort decision")
        candidate = self._file(record["candidate_name"])
        if candidate.is_file():
            if digest(candidate) != record["after_hash"]:
                raise ValueError("candidate changed during abort")
            candidate.unlink()
        self._unlock(txid)

    def clear_unprepared_lock(self, txid):
        """Safe only when no durable local receipt exists for this transaction."""
        if self.get(txid) is not None:
            raise ValueError("prepared trade cannot be discarded")
        self._unlock(txid)

    def apply(self, txid, *, after_replace=None):
        """Idempotent. Never replaces a changed original or a symlink."""
        record = self.get(txid)
        if record is None or record["decision"] != "commit":
            raise ValueError("no durable commit decision")
        original = self._file(record["save_name"])
        candidate = self._file(record["candidate_name"])
        if not original.is_file():
            raise ValueError("save missing during recovery")
        current = digest(original)
        if current != record["after_hash"]:
            if current != record["before_hash"] or not candidate.is_file() or digest(candidate) != record["after_hash"]:
                raise ValueError("save diverged; manual recovery required")
            os.replace(candidate, original)
            if after_replace:
                after_replace()  # Test-only fault injection before database acknowledgment.
            if os.name != "nt":
                fd = os.open(self.save_dir, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
        if digest(original) != record["after_hash"]:
            raise ValueError("installed save failed verification")
        with self._atomic():
            self.db.execute("UPDATE escrow SET applied=1 WHERE txid=?", (txid,))
        return record["after_hash"]

    def finish(self, txid):
        """Only after the server confirms that both saves were applied."""
        with self._atomic():
            record = self.get(txid)
            if record is None or record["decision"] != "commit" or not record["applied"]:
                raise ValueError("trade not locally applied")
            self.db.execute("UPDATE escrow SET completed=1 WHERE txid=?", (txid,))
        self._unlock(txid)
