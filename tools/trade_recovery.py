"""Reconcile an isolated profile before its game is allowed to load."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import socket
import time

from src.client.trade_storage import TradeStorage
from tools.menu_control import MenuControl

MAX_LINE = 196608


def recover(root: Path, profile: Path, port=17641, wait_seconds=60):
    storage = TradeStorage(profile / "saves")
    try:
        pending = storage.pending()
        if not pending:
            lock = profile / "trade-pending.lock"
            if lock.exists():
                txid = lock.read_text(encoding="ascii")
                record = storage.get(txid)
                if record is None:
                    storage.clear_unprepared_lock(txid)
                elif record["decision"] == "abort":
                    storage.finish_abort(txid)
                else:
                    raise RuntimeError("Inconsistent trade lock; the save stays blocked")
            return []
        sessions = {(r["session_host"], r["session_code"], r["session_mode"]) for r in pending}
        if len(sessions) != 1 or None in next(iter(sessions)):
            raise RuntimeError("Trade recovery has no single saved session")
        host, code, mode = next(iter(sessions))
        host = os.environ.get("ANIL_COOP_TRADE_RECOVERY_HOST", host)
        profile_id = hashlib.sha256((profile / "profile-id.txt").read_text().strip().encode()).hexdigest()[:32]
        control = MenuControl(root, server_port=port, profile=profile, trade_enabled=True)
        try:
            session = control.start(mode, host, code)
            def open_authenticated():
                for _ in range(20):
                    connection = socket.create_connection(("127.0.0.1", session["port"]), timeout=5)
                    connection.settimeout(5)
                    reader = connection.makefile("rb")
                    hello = {"type": mode, "session": code, "name": "Recovery", "profile": profile_id}
                    connection.sendall((json.dumps(hello, separators=(",", ":")) + "\n").encode())
                    line = reader.readline(MAX_LINE + 1)
                    answer = json.loads(line) if line else {}
                    if answer.get("type") == "welcome":
                        return connection, reader
                    reader.close()
                    connection.close()
                    if mode != "join" or answer.get("reason") != "no_session":
                        raise RuntimeError(f"Cannot join recovery room: {answer.get('reason', 'unknown')}")
                    time.sleep(0.5)
                raise RuntimeError("Host has not recreated the recovery room")

            sock, stream = open_authenticated()
            with sock, stream:

                def send(packet):
                    sock.sendall((json.dumps(packet, separators=(",", ":")) + "\n").encode())

                def read():
                    line = stream.readline(MAX_LINE + 1)
                    if not line or len(line) > MAX_LINE:
                        raise RuntimeError("Trade recovery connection closed")
                    return json.loads(line)

                def query(txid):
                    send({"type": "trade_status", "trade": txid})
                    while True:
                        answer = read()
                        if answer.get("trade") != txid and answer.get("txid") != txid:
                            continue
                        if answer.get("type") == "trade_error":
                            raise RuntimeError("Host has no durable decision for this trade")
                        if answer.get("type") == "trade_recovery":
                            return answer

                finished = []
                for local in pending:
                    txid = local["txid"]
                    deadline = time.monotonic() + wait_seconds
                    while True:
                        record = query(txid)
                        players = record.get("players")
                        digests = record.get("digests")
                        if not isinstance(players, list) or profile_id not in players or not isinstance(digests, list):
                            raise RuntimeError("Trade belongs to a different profile")
                        index = players.index(profile_id)
                        decision = record.get("decision")
                        if decision == "abort":
                            storage.decide(txid, "abort")
                            send({"type": "trade_aborted", "trade": txid})
                            finished.append((txid, "abort"))
                            break
                        if decision == "commit":
                            storage.decide(txid, "commit")
                            storage.apply(txid)
                            send({"type": "trade_applied", "trade": txid})
                            updated = query(txid)
                            if updated.get("applied") == [True, True]:
                                storage.finish(txid)
                                finished.append((txid, "commit"))
                                break
                        elif decision is None:
                            if local["decision"] == "commit" or local["applied"]:
                                raise RuntimeError("Server lost a definitive trade decision")
                            send({"type": "trade_prepared", "trade": txid,
                                  "own_digest": digests[index], "incoming_digest": digests[1-index]})
                        else:
                            raise RuntimeError("Unknown durable trade decision")
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Waiting for the other player to recover the trade")
                        time.sleep(1)
                return finished
        finally:
            control.dispose()
    finally:
        storage.close()
