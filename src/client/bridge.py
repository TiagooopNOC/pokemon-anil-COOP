"""Local game socket to authenticated remote session server. Portable Python."""
import hashlib
import hmac
import json
import socket
import socketserver
import threading

from src.server.session_server import LOCAL_SECRET, private_bind

MAX_LINE = 4096


def proof(secret, nonce, message):
    fields = (nonce, message.get("type", ""), message.get("session", ""),
              message.get("name", ""), message.get("resume", ""))
    if not all(isinstance(x, str) for x in fields):
        raise ValueError("invalid hello")
    return hmac.new(secret.encode(), "\n".join(fields).encode(), hashlib.sha256).hexdigest()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        remote = None
        remote_file = None
        try:
            line = self.rfile.readline(MAX_LINE + 1)
            if not line.endswith(b"\n") or len(line) > MAX_LINE:
                return
            message = json.loads(line)
            if not isinstance(message, dict) or message.get("type") not in ("create", "join"):
                return
            remote = socket.create_connection((self.server.remote_host, self.server.remote_port), timeout=5)
            remote.settimeout(None)
            remote_file = remote.makefile("rb")
            challenge = json.loads(remote_file.readline(MAX_LINE + 1))
            if challenge.get("type") != "challenge" or not isinstance(challenge.get("nonce"), str):
                return
            message["proof"] = proof(self.server.secret, challenge["nonce"], message)
            remote.sendall((json.dumps(message, separators=(",", ":")) + "\n").encode())

            def upstream():
                try:
                    while True:
                        packet = self.rfile.readline(MAX_LINE + 1)
                        if not packet or len(packet) > MAX_LINE or not packet.endswith(b"\n"):
                            break
                        remote.sendall(packet)
                except OSError:
                    pass
                finally:
                    try:
                        remote.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass

            worker = threading.Thread(target=upstream, daemon=True)
            worker.start()
            for packet in remote_file:
                self.connection.sendall(packet)
        except (OSError, ValueError, UnicodeError):
            pass
        finally:
            if remote_file:
                remote_file.close()
            if remote:
                remote.close()


class Bridge(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, remote_host, remote_port, secret):
        if remote_host != "localhost" and not private_bind(remote_host):
            raise ValueError("Server host must be a private IPv4 address")
        self.remote_host = remote_host
        self.remote_port = remote_port
        self.secret = secret
        super().__init__(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    @property
    def port(self):
        return self.server_address[1]

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join()
