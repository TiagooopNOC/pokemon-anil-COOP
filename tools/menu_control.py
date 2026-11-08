"""Loopback-only control plane for the in-game multiplayer menu."""
from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import secrets
import socket
import socketserver
import subprocess
import sys
import time

from src.client.bridge import Bridge
from src.server.session_server import private_bind

ROOM_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
MAX_REQUEST = 512


def room_secret(code):
    return hashlib.sha256(("anil-coop-room-v1:" + code).encode()).hexdigest()


def local_addresses():
    found = set()
    try:
        for _, _, _, _, sockaddr in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            address = sockaddr[0]
            if private_bind(address) and not ipaddress.ip_address(address).is_loopback:
                found.add(address)
    except OSError:
        pass
    return sorted(found)


class MenuControl:
    def __init__(self, root, *, server_port=17641):
        self.root = root
        self.server_port = server_port
        self.server = None
        self.bridge = None
        self.session = None

    def close(self):
        if self.bridge:
            self.bridge.close()
            self.bridge = None
        if self.server:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait()
            self.server = None
        self.session = None

    def start(self, operation, host, code=""):
        if operation not in ("create", "join"):
            raise ValueError("Opción inválida")
        if not isinstance(host, str) or not private_bind(host):
            raise ValueError("Ingresá una IP privada de LAN o VPN")
        if operation == "create":
            if not code:
                code = "".join(secrets.choice(ROOM_ALPHABET) for _ in range(12))
            elif not isinstance(code, str) or len(code) != 12 or any(c not in ROOM_ALPHABET for c in code):
                raise ValueError("Código de sala inválido")
        elif not isinstance(code, str) or len(code) != 12 or any(c not in ROOM_ALPHABET for c in code):
            raise ValueError("El código de sala debe tener 12 caracteres")
        self.close()
        secret = room_secret(code)
        try:
            if operation == "create":
                env = dict(os.environ, ANIL_COOP_SECRET=secret)
                self.server = subprocess.Popen(
                    [sys.executable, "-B", str(self.root / "src/server/session_server.py"),
                     "--bind", host, "--port", str(self.server_port)],
                    cwd=self.root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 5
            while True:
                if self.server and self.server.poll() is not None:
                    raise ValueError("No se pudo iniciar el servidor en esa IP")
                try:
                    with socket.create_connection((host, self.server_port), timeout=0.3):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise ValueError("No se encuentra el servidor; revisá IP, VPN y firewall")
                    time.sleep(0.1)
            self.bridge = Bridge(host, self.server_port, secret)
            self.session = {"mode": operation, "host": host, "code": code,
                            "port": self.bridge.port}
            return self.session.copy()
        except Exception:
            self.close()
            raise


class ControlHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            line = self.rfile.readline(MAX_REQUEST + 1)
            if len(line) > MAX_REQUEST or not line.endswith(b"\n"):
                return
            data = json.loads(line)
            if not isinstance(data, dict) or not secrets.compare_digest(
                str(data.get("token", "")), self.server.token):
                return
            operation = data.get("op")
            if operation == "stop":
                self.server.control.close()
                result = {"ok": True}
            elif operation == "status":
                result = {"ok": True, "session": self.server.control.session,
                          "addresses": local_addresses()}
            else:
                result = {"ok": True, **self.server.control.start(
                    operation, data.get("host"), data.get("code", ""))}
        except (ValueError, OSError, UnicodeError, json.JSONDecodeError) as error:
            result = {"ok": False, "error": str(error)}
        self.wfile.write((json.dumps(result, separators=(",", ":")) + "\n").encode())


class ControlServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, control):
        self.control = control
        self.token = secrets.token_hex(16)
        super().__init__(("127.0.0.1", 0), ControlHandler)

    def close(self):
        self.shutdown()
        self.server_close()
        self.control.close()
