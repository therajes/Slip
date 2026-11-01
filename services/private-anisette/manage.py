#!/usr/bin/env python3
"""Manage the private service and retain failed compatibility experiments for diagnosis."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from datetime import datetime, timezone
from urllib.request import urlopen

REVISION = "684895737aaf1a1c4586fcd5b67509ffd500a36c"
IMAGE = "slip/private-anisette:compat-6848957"
BACKEND_IMAGE = "dadoum/anisette-v3-server@sha256:8577c27cb7592900947960799bf03c79a53bf857ed951e4c48ef6e06c6e0f488"
PROXY_IMAGE = "nginx@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236"
CONTAINER = "slip-anisette-candidate"
BACKEND = "slip-anisette-candidate-backend"
NETWORK = "slip-anisette-private"
VOLUME = "slip-anisette-candidate-data"
PRODUCTION_VOLUME = "slip-anisette-private-data"
CONTEXT = os.environ.get("SLIP_DOCKER_CONTEXT", "colima")
DOCKER = ["docker", "--context", CONTEXT]
DATA = "/home/Alcoholic/.config/anisette-v3"
HERE = Path(__file__).resolve().parent
STAGING_ROOT = HERE.parents[1] / "native/build/private-anisette"
CA_URL = "https://curl.se/ca/cacert-2026-10-20.pem"
CA_SHA256 = "796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe"


def run(*args, capture=False, **kwargs):
    return subprocess.run([*DOCKER, *args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None, **kwargs)


def exists(kind, name):
    return subprocess.run([*DOCKER, kind, "inspect", name], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def build():
    context = STAGING_ROOT / "context"
    context.mkdir(parents=True, exist_ok=True)
    for name in ["Dockerfile", "compatibility.patch", ".dockerignore"]:
        shutil.copy2(HERE / name, context / name)
    ca = context / "bootstrap-ca-bundle.pem"
    if not ca.exists() or hashlib.sha256(ca.read_bytes()).hexdigest() != CA_SHA256:
        data = urlopen(CA_URL, timeout=45).read()
        if hashlib.sha256(data).hexdigest() != CA_SHA256:
            raise SystemExit("Public CA bundle does not match the reviewed checksum; build stopped.")
        ca.write_bytes(data)
    env = os.environ.copy()
    if subprocess.run([*DOCKER, "buildx", "version"], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
        env["DOCKER_BUILDKIT"] = "0"
    run("build", "--pull", "--build-arg", f"UPSTREAM_REVISION={REVISION}",
        "--tag", IMAGE, str(context), env=env)
    run("image", "inspect", IMAGE, "--format", "Image ID: {{.Id}}")


def prepare_volume(source, image, volume=VOLUME, purpose="candidate"):
    if not exists("volume", volume):
        run("volume", "create", "--label", f"app.slip.private-anisette={purpose}", volume)
    if source:
        result = subprocess.run([*DOCKER, "run", "--rm", "--entrypoint", "/bin/sh",
                                 "--mount", f"type=volume,source={volume},target=/data,readonly",
                                 image, "-c", "test -f /data/.slip-seed-ready"])
        if result.returncode:
            labels = json.loads(run("volume", "inspect", volume, capture=True).stdout)[0].get("Labels", {})
            if labels.get("app.slip.private-anisette") != purpose:
                raise SystemExit("Existing volume is not owned by this service recipe; inspect it first.")
            users = run("ps", "--quiet", "--filter", f"volume={volume}", capture=True).stdout.strip()
            if users:
                raise SystemExit("Candidate volume is in use; stop its containers before seeding.")
            # Keep private provisioning data in an anonymous pipe between Docker
            # processes. No host staging file or configuration contents are printed.
            copying = subprocess.Popen([*DOCKER, "cp", f"{source}:{DATA}/.", "-"],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                run("run", "--rm", "--interactive", "--user", "0", "--entrypoint", "/bin/sh",
                    "--mount", f"type=volume,source={volume},target=/data", image,
                    "-c", "tar -xf - -C /data && chown -R 1000:1000 /data && chmod 700 /data && touch /data/.slip-seed-ready",
                    stdin=copying.stdout)
            finally:
                copying.stdout.close()
                copying.communicate(timeout=30)
            if copying.returncode:
                raise SystemExit("Could not copy the original server data; original server is unchanged.")


def candidate(source):
    if exists("container", CONTAINER):
        raise SystemExit(f"{CONTAINER} already exists; inspect it before replacing it.")
    prepare_volume(source, IMAGE)
    run("run", "--detach", "--name", CONTAINER, "--restart", "unless-stopped",
        "--publish", "127.0.0.1:6970:6969",
        "--mount", f"type=volume,source={VOLUME},target={DATA}",
        "--label", "app.slip.private-anisette=candidate",
        "--log-opt", "max-size=10m", "--log-opt", "max-file=3", IMAGE)
    await_health()


def proxy_candidate(source):
    if exists("container", CONTAINER) or exists("container", BACKEND):
        raise SystemExit("A candidate container already exists; inspect it before replacing it.")
    if not exists("network", NETWORK):
        run("network", "create", "--label", "app.slip.private-anisette=candidate", NETWORK)
    prepare_volume(source, BACKEND_IMAGE)
    run("run", "--detach", "--name", BACKEND, "--restart", "unless-stopped",
        "--network", NETWORK, "--network-alias", "anisette-backend",
        "--mount", f"type=volume,source={VOLUME},target={DATA}",
        "--label", "app.slip.private-anisette=candidate-backend",
        "--log-opt", "max-size=10m", "--log-opt", "max-file=3",
        BACKEND_IMAGE, "--timeout", "30000")
    run("run", "--detach", "--name", CONTAINER, "--restart", "unless-stopped",
        "--network", NETWORK, "--publish", "127.0.0.1:6970:6969",
        "--mount", f"type=bind,source={HERE / 'nginx.conf'},target=/etc/nginx/conf.d/default.conf,readonly",
        "--label", "app.slip.private-anisette=candidate-proxy",
        "--health-cmd", "wget -q -O /dev/null http://127.0.0.1:6969/v3/client_info",
        "--health-interval", "5s", "--health-timeout", "3s", "--health-retries", "3",
        "--log-opt", "max-size=10m", "--log-opt", "max-file=3", PROXY_IMAGE)
    await_health()


def await_health():
    for _ in range(35):
        metadata = json.loads(run("inspect", CONTAINER, capture=True).stdout)[0]
        if metadata["State"].get("Health", {}).get("Status") == "healthy":
            print("Candidate healthy at http://127.0.0.1:6970; original port 6969 unchanged.")
            return
        if not metadata["State"]["Running"]:
            raise SystemExit("Candidate stopped. Inspect its bounded log locally; original server is unchanged.")
        time.sleep(2)
    raise SystemExit("Candidate did not become healthy within 70 seconds; original server is unchanged.")


def private_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(path.name + f".{time.time_ns()}.tmp")
    with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def restart_value(policy):
    value = policy.get("Name") or "no"
    if value == "on-failure" and policy.get("MaximumRetryCount"):
        value += f":{policy['MaximumRetryCount']}"
    return value


def restore(snapshot):
    original_id = snapshot["originalId"]
    if exists("container", "anisette"):
        current = json.loads(run("inspect", "anisette", capture=True).stdout)[0]
        if current["Id"] != original_id:
            if current["Config"].get("Labels", {}).get("app.slip.private-anisette") != "private-server":
                raise RuntimeError("The anisette name belongs to an unrecognized container; inspect it before restoring.")
            run("update", "--restart", "no", current["Id"])
            if current["State"]["Running"]:
                run("stop", "--time", "10", current["Id"])
            run("rename", current["Id"], f"anisette-retired-private-{time.time_ns()}")
    original = json.loads(run("inspect", original_id, capture=True).stdout)[0]
    if original["Name"] != "/anisette":
        run("rename", original_id, "anisette")
    run("update", "--restart", restart_value(snapshot["originalRestart"]), original_id)
    if snapshot["originalRunning"]:
        run("start", original_id)


def setup_private():
    if not exists("container", "anisette"):
        raise SystemExit("Original anisette container is missing; no configuration was changed.")
    original = json.loads(run("inspect", "anisette", capture=True).stdout)[0]
    if original["Config"].get("Labels", {}).get("app.slip.private-anisette") == "private-server":
        print("The private service is already configured; inspect its health before changing it.")
        return
    if original["Image"] != BACKEND_IMAGE.split("@", 1)[1]:
        raise SystemExit("Original image differs from the reviewed pin; inspect it before changing it.")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    snapshot = {
        "version": 1, "createdAt": datetime.now(timezone.utc).isoformat(),
        "originalId": original["Id"], "originalName": original["Name"],
        "rollbackName": f"anisette-before-slip-private-{stamp}",
        "originalRestart": original["HostConfig"]["RestartPolicy"],
        "originalRunning": original["State"]["Running"],
        "originalImageId": original["Image"], "originalImageTag": original["Config"]["Image"],
        "originalArgs": original["Args"],
        "originalPorts": original["HostConfig"]["PortBindings"],
        "originalMounts": original["Mounts"], "newVolume": PRODUCTION_VOLUME,
    }
    backup = STAGING_ROOT / f"production-backup-{stamp}.json"
    latest = STAGING_ROOT / "latest-production-backup.json"
    private_json(backup, snapshot)
    private_json(latest, snapshot)
    changed = False
    try:
        changed = True
        run("update", "--restart", "no", original["Id"])
        if original["State"]["Running"]:
            run("stop", "--time", "10", original["Id"])
        run("rename", original["Id"], snapshot["rollbackName"])
        prepare_volume(snapshot["rollbackName"], BACKEND_IMAGE,
                       volume=PRODUCTION_VOLUME, purpose="private-server")
        run("run", "--detach", "--name", "anisette", "--restart", "unless-stopped",
            "--publish", "127.0.0.1:6969:6969",
            "--mount", f"type=volume,source={PRODUCTION_VOLUME},target={DATA}",
            "--label", "app.slip.private-anisette=private-server",
            "--health-cmd", "curl --fail --silent --max-time 5 http://127.0.0.1:6969/v3/client_info >/dev/null",
            "--health-interval", "5s", "--health-timeout", "7s", "--health-retries", "3",
            "--log-opt", "max-size=10m", "--log-opt", "max-file=3",
            BACKEND_IMAGE, "--timeout", "30000")
        for _ in range(35):
            current = json.loads(run("inspect", "anisette", capture=True).stdout)[0]
            if current["State"].get("Health", {}).get("Status") == "healthy":
                with urlopen("http://127.0.0.1:6969/v3/client_info", timeout=8) as response:
                    metadata = json.load(response)
                if not metadata.get("client_info") or not metadata.get("user_agent"):
                    raise RuntimeError("Private service returned incomplete public metadata.")
                snapshot["newContainerId"] = current["Id"]
                snapshot["healthy"] = True
                private_json(backup, snapshot)
                private_json(latest, snapshot)
                print("Private service healthy on http://127.0.0.1:6969; generator unchanged, timeout 30 seconds.")
                print(f"Original container preserved as {snapshot['rollbackName']}; backup metadata: {backup}")
                return
            if not current["State"]["Running"]:
                raise RuntimeError("New private service stopped before becoming healthy.")
            time.sleep(2)
        raise RuntimeError("New private service did not become healthy within 70 seconds.")
    except BaseException:
        if changed:
            restore(snapshot)
            print("Private setup failed; original container and restart policy restored.")
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "candidate", "proxy-candidate", "setup-private", "restore-original"])
    parser.add_argument("--seed-from", default="anisette",
                        help="Existing container to copy configuration from; use an empty string for fresh data.")
    parser.add_argument("--allow-failed-experiment", action="store_true",
                        help="Explicitly allow starting the retained Windows workaround, which failed the user's sign-in test.")
    parser.add_argument("--backup", type=Path, default=STAGING_ROOT / "latest-production-backup.json",
                        help="Private metadata snapshot used by restore-original.")
    args = parser.parse_args()
    if args.action in ["candidate", "proxy-candidate"] and not args.allow_failed_experiment:
        raise SystemExit("This Windows-description experiment failed the user's sign-in test. It is retained for diagnosis only; starting it requires --allow-failed-experiment.")
    if args.action == "build":
        build()
    elif args.action == "candidate":
        candidate(args.seed_from)
    elif args.action == "proxy-candidate":
        proxy_candidate(args.seed_from)
    elif args.action == "setup-private":
        setup_private()
    else:
        restore(json.loads(args.backup.read_text()))
