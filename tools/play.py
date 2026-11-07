"""Interactive private-network launcher for the two-player alpha (stdlib only)."""
from __future__ import annotations

import argparse
import getpass
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time

from h0 import ROOT, SafetyError, read_json
sys.path.insert(0, str(ROOT))
from src.server.session_server import private_bind


def game_command(platform, client, host, port, session, mode):
    slot = ROOT / "vendor/gameslot/gameslot.py"
    if platform == "nt":
        return [sys.executable, "-B", str(ROOT / "tools/windows_network.py"),
                "--client", client, "--server-host", host, "--port", str(port),
                "--session", session, "--mode", mode, "--gameslot", str(slot), "--coop-battles"]
    command = [sys.executable, "-B", str(ROOT / "tools/wine_smoke.py"), "--client", client,
               "--server-host", host, "--port", str(port), "--session", session,
               "--gameslot", str(slot), "--coop-battles", "--play"]
    if mode == "create":
        command += ["--host-client", client]
    return command


def validate_connection(host, port, session):
    if not private_bind(host):
        raise SafetyError("Usá una IP privada de LAN/VPN; no se permiten IP públicas ni 0.0.0.0.")
    if not 1 <= port <= 65535 or not session.isascii() or not session.isalnum() or not 6 <= len(session) <= 12:
        raise SafetyError("Puerto inválido o código de sesión inválido (6–12 letras/números).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client")
    parser.add_argument("--mode", choices=("create", "join"))
    parser.add_argument("--server-host")
    parser.add_argument("--port", type=int, default=17641)
    parser.add_argument("--session")
    args = parser.parse_args()
    workspace = ROOT / "local/workspace.json"
    if not workspace.exists():
        source = input("Carpeta de tu instalación original (se creará una copia): ").strip().strip('"')
        subprocess.run([sys.executable, "-B", str(ROOT / "tools/h0.py"), "prepare",
                        "--source", source, "--clients", "1"], cwd=ROOT, check=True)
    clients = [entry["client"] for entry in read_json(workspace)["clients"]]
    client = args.client or (clients[0] if len(clients) == 1 else input(f"Perfil [{', '.join(clients)}]: ").strip())
    if client not in clients:
        raise SafetyError("Elegí uno de los perfiles aislados preparados.")
    mode = args.mode or ({"1": "create", "2": "join"}.get(input("1 Crear sesión / 2 Unirme: ").strip()))
    if mode not in ("create", "join"):
        raise SafetyError("Elegí 1 o 2.")
    host = args.server_host or input("IP privada LAN/VPN del anfitrión: ").strip()
    session = (args.session or input("Código compartido (6–12 letras/números): ").strip()).upper()
    validate_connection(host, args.port, session)
    secret = os.environ.get("ANIL_COOP_SECRET")
    if not secret:
        if mode == "create":
            secret = secrets.token_urlsafe(24)
            print(f"Clave de esta sesión para tu amigo: {secret}")
        else:
            secret = getpass.getpass("Clave que te dio el anfitrión: ")
    if len(secret) < 16:
        raise SafetyError("La clave debe tener al menos 16 caracteres.")
    subprocess.run([sys.executable, "-B", str(ROOT / "tools/install_presence.py"),
                    "--clients", client], cwd=ROOT, check=True)
    env = dict(os.environ, ANIL_COOP_SECRET=secret)
    server = None
    server_log = None
    try:
        if mode == "create":
            log_dir = ROOT / "local/reports"
            log_dir.mkdir(exist_ok=True)
            server_log = (log_dir / f"play-server-{time.time_ns()}.log").open("x", encoding="utf-8")
            server = subprocess.Popen([sys.executable, "-B", str(ROOT / "src/server/session_server.py"),
                                       "--bind", host, "--port", str(args.port)], cwd=ROOT, env=env,
                                      stdout=server_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 8
            while True:
                if server.poll() is not None:
                    raise SafetyError("El servidor no pudo iniciar. Revisá la IP o si el puerto está ocupado.")
                try:
                    with socket.create_connection((host, args.port), timeout=0.25):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise SafetyError("El servidor no está disponible en la IP indicada.")
                    time.sleep(0.1)
            print(f"Sesión {session} en {host}:{args.port}. Compartí IP, código y clave con tu amigo.")
        print("Cargá o creá tu partida. Para combatir juntos, hablen con el mismo entrenador y elijan sus equipos.")
        print("Guardá desde el juego antes de cerrar. Cada jugador conserva su propia aventura.")
        return subprocess.call(game_command(os.name, client, host, args.port, session, mode), cwd=ROOT, env=env)
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        if server_log:
            server_log.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SafetyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"No se pudo iniciar: {error}", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
