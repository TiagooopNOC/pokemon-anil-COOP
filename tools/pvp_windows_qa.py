"""Run two native Windows clients in a fresh QA workspace under local/."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import threading
import uuid

from src.client.bridge import Bridge
from src.server.session_server import Server
from tools.h0 import ROOT, launch_plan, launch_windows, prepare
from tools.install_presence import install_presence


def run(source, scenario):
    if os.name != "nt":
        raise RuntimeError("Windows x64 required")
    workspace = ROOT / "local" / f"pvp-qa-{uuid.uuid4().hex}"
    print(f"QA workspace: {workspace}", flush=True)
    def progress(phase, done=0, total=0):
        if done == 0 or done == total:
            print(f"{phase}: {done}/{total}", flush=True)

    prepare(workspace, source, 2, assets=ROOT, progress=progress)
    names = ["client01", "client02"]
    install_presence(workspace, names, assets=ROOT)
    plans = launch_plan(workspace, names)["clients"]
    fixture = (ROOT / "tests/pvp_windows_qa.rb").read_bytes()
    for plan in plans:
        overlay = Path(plan["cwd"]) / "CoopDev"
        (overlay / "pvp_windows_qa.rb").write_bytes(fixture)
        with (overlay / "loader.rb").open("ab") as loader:
            loader.write(b'\nload "CoopDev/pvp_windows_qa.rb"\n')
    with Server(("127.0.0.1", 0)) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        bridge = Bridge("127.0.0.1", server.server_address[1], server.secret)

        def launch(plan, role):
            launch_windows(workspace, [plan["client"]], None, environment={
                "ANIL_COOP_PVP": "1", "ANIL_PVP_QA_MODE": scenario, "ANIL_COOP_SESSION": "PVPQA1",
                "ANIL_COOP_PORT": str(bridge.port), "ANIL_COOP_MODE": role,
                "ANIL_COOP_NAME": plan["client"],
            })
            report = Path(plan["save_directory"]).parent / "qa-pvp-result.json"
            return json.loads(report.read_text(encoding="utf-8"))

        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                jobs = [pool.submit(launch, plan, role) for plan, role in zip(plans, ("create", "join"))]
                results = [job.result() for job in jobs]
        finally:
            bridge.close()
            server.shutdown()
            thread.join()
    print(json.dumps(results, indent=2))
    assert all(row.get("originals") and row.get("save_intact") and row.get("map_restored")
               for row in results), "QA failed before verifying save integrity and map restoration"
    if scenario == "decline":
        assert all(row["declined"] and row["connected"] for row in results)
    elif scenario == "disconnect":
        assert results[0]["error"] == "battle_disconnect"
        assert results[1]["error"] == "QA transport closed"
    else:
        assert all(row["complete"] and row["connected"] and row["reload"] and row["position_after"] and
                   row["turns"] >= 2 for row in results)
        assert [row["decision"] for row in results] == ([2, 1] if scenario == "guest" else [1, 2])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--scenario", choices=("host", "guest", "decline", "switch", "disconnect"), default="host")
    args = parser.parse_args()
    run(args.source, args.scenario)


if __name__ == "__main__":
    main()
