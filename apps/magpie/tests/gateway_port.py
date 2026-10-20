#!/usr/bin/env python3
"""Exercise the real gateway API and lifecycle in an isolated network namespace."""
import argparse
import copy
import hashlib
import http.cookiejar
import io
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

KEY = "MgPortTest_0123456789-abcdef"
WEB = 3430
DEFAULT = 3425
CUSTOM = 34425
passed = 0


def check(condition, description):
    global passed
    if not condition:
        raise AssertionError(description)
    passed += 1
    print("PASS " + description, flush=True)


def listening(port):
    result = subprocess.run(
        ["/usr/bin/ss", "-H", "-ltn", "sport = :%s" % port],
        capture_output=True, text=True, check=True,
    )
    return bool(result.stdout.strip())


def wait_for(predicate, seconds=10):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if predicate():
            return True
        time.sleep(0.2)
    return bool(predicate())


def gateway_ok(port):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%s/v1/models" % port, timeout=2) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


SOURCE = Path(__file__).resolve().parents[1]
DEFAULT_PROVENANCE = SOURCE / "tests/fixtures/previous-main.provenance.json"
VERSION_PATTERN = r"[0-9]+(?:\.[0-9]+)+(?:-[0-9]+)?"


def package_version(path):
    values = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith(("#", ";")):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    if values.get("appname") != "magpie" or not re.fullmatch(VERSION_PATTERN, values.get("version", "")):
        raise ValueError("invalid Magpie manifest identity or version")
    return values["version"]


def previous_controller(provenance, controller=None, previous_fpk=None):
    info = json.loads(provenance.read_text())
    if info.get("schema_version") != 1 or info.get("appname") != "magpie":
        raise ValueError("invalid previous-controller provenance")
    if not re.fullmatch(VERSION_PATTERN, info.get("package_version", "")):
        raise ValueError("invalid previous package version")
    fixture, source = info["fixture"], info["source_fpk"]
    for digest in (fixture["sha256"], source["sha256"]):
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("invalid provenance SHA-256")
    if source["member"] != "cmd/main":
        raise ValueError("previous controller must come from cmd/main")
    if source["name"] != "magpie_%s_x86.fpk" % info["package_version"]:
        raise ValueError("previous FPK name does not match its package version")
    if previous_fpk is not None:
        # Hash and extract from the same buffer so an input replacement cannot
        # exchange the controller after the original FPK has been checked.
        raw = previous_fpk.read_bytes()
        if hashlib.sha256(raw).hexdigest() != source["sha256"]:
            raise ValueError("previous FPK checksum mismatch")
        with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
            member = archive.getmember(source["member"])
            manifest_member = archive.getmember("manifest")
            if not member.isfile() or not manifest_member.isfile():
                raise ValueError("previous FPK controller and manifest must be regular files")
            content = archive.extractfile(member).read()
            manifest_text = archive.extractfile(manifest_member).read().decode()
        versions = [line.split("=", 1)[1].strip() for line in manifest_text.splitlines()
                    if "=" in line and line.split("=", 1)[0].strip() == "version"]
        if versions != [info["package_version"]]:
            raise ValueError("previous FPK version does not match provenance")
    else:
        name = fixture["file"]
        if Path(name).name != name or name in (".", ".."):
            raise ValueError("invalid fixture filename")
        path = controller if controller is not None else provenance.parent / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("previous controller must be a regular file")
        content = path.read_bytes()
    if hashlib.sha256(content).hexdigest() != fixture["sha256"]:
        raise ValueError("previous controller checksum mismatch")
    return content, info


def execute(project, old_controller, previous_version):
    check(os.getuid() != 0, "test identity is non-root")
    host_netns = os.environ.get("MAGPIE_TEST_HOST_NETNS")
    check(host_netns is not None and os.readlink("/proc/self/ns/net") != host_netns,
          "network namespace is separate from installed services")
    check(all(not listening(port) for port in (WEB, DEFAULT, CUSTOM)), "test ports are initially free")
    current_version = package_version(project / "manifest")

    with tempfile.TemporaryDirectory(prefix="mgports.") as folder:
        root = Path(folder)
        target = root / "target"
        state = root / "apps/magpie/var"
        (target / "bin").mkdir(parents=True)
        for path in (state, root / "etc", root / "tmp", root / "home"):
            path.mkdir(parents=True)
        binary = target / "bin/magpie"
        shutil.copy2(project / "app/bin/magpie", binary)
        binary.chmod(0o755)
        main = project / "cmd/main"
        pid_file = state / "run/web.pid"
        config = state / "xdg/config/magpie/settings.json"
        key_file = state / "web.key"
        environment = dict(os.environ)
        environment.pop("MAGPIE_ADDR", None)
        environment.update({
            "TRIM_APPNAME": "magpie", "TRIM_APPVER": current_version,
            "TRIM_OLD_APPVER": previous_version, "TRIM_APPDEST": str(target),
            "TRIM_PKGVAR": str(state), "TRIM_PKGETC": str(root / "etc"),
            "TRIM_PKGTMP": str(root / "tmp"), "TRIM_PKGHOME": str(root / "home"),
            "TRIM_UID": str(os.getuid()), "TRIM_GID": str(os.getgid()),
            "TRIM_TEMP_LOGFILE": str(root / "tmp/lifecycle.log"),
        })
        squatter = None
        tracked = set()

        def lifecycle(phase, script=main, expected=0, extra=None):
            env = dict(environment)
            if script != main:
                env["TRIM_APPVER"] = previous_version
            env.update(extra or {})
            result = subprocess.run(["/bin/bash", str(script), phase], env=env,
                                    capture_output=True, text=True, timeout=100)
            if pid_file.exists():
                try:
                    tracked.add(int(pid_file.read_text().strip()))
                except ValueError:
                    pass
            check(result.returncode == expected,
                  "%s returns %s%s" % (phase, expected, " (previous controller)" if script != main else ""))
            return result

        def pid():
            return int(pid_file.read_text().strip())

        def save(settings):
            config.write_text(json.dumps(settings, indent=2) + "\n")
            config.chmod(0o600)

        def occupy(port):
            sock = socket.socket()
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", port))
            sock.listen(5)
            return sock

        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        )

        def api(path, body=None):
            data = None if body is None else json.dumps(body).encode()
            request = urllib.request.Request(
                "http://127.0.0.1:%s%s" % (WEB, path), data=data,
                headers={"Content-Type": "application/json", "Origin": "http://127.0.0.1:%s" % WEB},
            )
            with opener.open(request, timeout=10) as response:
                return json.load(response)

        try:
            lifecycle("install_callback", extra={"wizard_web_key": KEY})
            lifecycle("start", extra={"MAGPIE_ADDR": "127.0.0.1:34999"})
            check(gateway_ok(DEFAULT), "fresh gateway uses the official loopback default 3425")
            initial_pid = pid()
            proc_env = Path("/proc/%s/environ" % initial_pid).read_bytes().split(b"\0")
            check(not any(item.startswith(b"MAGPIE_ADDR=") for item in proc_env),
                  "MAGPIE_ADDR is absent even when inherited by the lifecycle")
            check((state / "logs").stat().st_mode & 0o777 == 0o700, "log directory remains 0700")
            check((state / "logs/web.log").stat().st_mode & 0o777 == 0o600, "log file remains 0600")
            with opener.open("http://127.0.0.1:%s/?k=%s" % (WEB, KEY), timeout=5) as response:
                check(response.status == 200, "management login succeeds")
            settings = api("/api/settings")
            check(not settings.get("addrEnv"), "settings API reports no address environment override")
            check(settings["gateway"] == "http://127.0.0.1:3425", "settings API reports the default gateway")

            changed = api("/api/settings/port", {"port": CUSTOM})
            check(changed["settings"]["port"] == CUSTOM, "the real UI API accepts a custom gateway port")
            check(wait_for(lambda: gateway_ok(CUSTOM) and not listening(DEFAULT)),
                  "gateway moves to the custom port and releases 3425")
            persisted = json.loads(config.read_text())
            check(persisted["port"] == CUSTOM, "custom port is persisted to Magpie settings")
            state_reply = lifecycle("status")
            check(str(CUSTOM) in state_reply.stdout, "status displays the configured custom port")
            lifecycle("start")
            check(pid() == initial_pid, "idempotent start keeps the PID after a UI port change")
            lifecycle("stop")
            check(not listening(WEB) and not listening(CUSTOM), "stop releases management and custom gateway ports")

            squatter = occupy(DEFAULT)
            lifecycle("start")
            check(gateway_ok(CUSTOM), "an unrelated listener on 3425 does not block the configured gateway")
            check(pid() != initial_pid, "cold start creates a new PID")
            lifecycle("status")
            lifecycle("stop")
            check(listening(DEFAULT), "stopping the package leaves the unrelated default-port listener intact")
            squatter.close()
            squatter = occupy(CUSTOM)
            lifecycle("start", expected=1)
            lifecycle("status", expected=1)
            check(listening(CUSTOM) and not listening(WEB), "configured-port conflict fails before daemon creation")
            squatter.close()
            squatter = None

            for value in ("34425", 65536, -1, 1.5, True):
                invalid = copy.deepcopy(persisted)
                invalid["port"] = value
                save(invalid)
                before = hashlib.sha256(config.read_bytes()).hexdigest()
                lifecycle("start", expected=1)
                lifecycle("status", expected=1)
                check(hashlib.sha256(config.read_bytes()).hexdigest() == before,
                      "invalid port %r leaves settings unchanged" % value)
            config.write_text('{"port":')
            lifecycle("start", expected=1)
            lifecycle("status", expected=1)
            save(dict(persisted, port=WEB))
            lifecycle("start", expected=1)

            for default_value in (0, None, "missing"):
                defaults = copy.deepcopy(persisted)
                if default_value == "missing":
                    defaults.pop("port", None)
                else:
                    defaults["port"] = default_value
                save(defaults)
                lifecycle("start")
                check(gateway_ok(DEFAULT), "port=%r follows the official default" % default_value)
                lifecycle("stop")

            save(persisted)
            lifecycle("start")
            config.write_text('{"port":')
            lifecycle("stop")
            check(not listening(WEB) and not listening(CUSTOM), "corrupt settings do not prevent process shutdown")
            save(persisted)

            # Run the exact old controller bytes verified before starting tests.
            # The previous release already honors the saved UI port; this proves
            # upgrade handover rather than recreating its earlier port defect.
            old_main = root / "previous-main"
            old_main.write_bytes(old_controller)
            old_main.chmod(0o755)
            lifecycle("start", script=old_main)
            check(gateway_ok(CUSTOM) and not listening(DEFAULT),
                  "previous controller follows the preserved UI setting")
            old_pid = pid()
            before_config = hashlib.sha256(config.read_bytes()).hexdigest()
            before_key = hashlib.sha256(key_file.read_bytes()).hexdigest()
            lifecycle("upgrade_init")
            check(all(not listening(port) for port in (WEB, DEFAULT, CUSTOM)),
                  "incoming upgrade_init stops the previous instance")
            lifecycle("upgrade_callback")
            check(gateway_ok(CUSTOM) and not listening(DEFAULT), "upgrade starts the gateway at the preserved UI setting")
            check(pid() != old_pid, "upgrade replaces the old daemon PID")
            check(hashlib.sha256(config.read_bytes()).hexdigest() == before_config,
                  "upgrade preserves settings byte-for-byte")
            check(hashlib.sha256(key_file.read_bytes()).hexdigest() == before_key,
                  "upgrade preserves the management key byte-for-byte")
            lifecycle("status")
            lifecycle("stop")
            check(all(not listening(port) for port in (WEB, DEFAULT, CUSTOM)), "all test service ports are released")
            print("PASS=%s FAIL=0" % passed, flush=True)
        finally:
            if squatter is not None:
                squatter.close()
            subprocess.run(["/bin/bash", str(main), "stop"], env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=50)
            # Never use a global process-name kill in test cleanup.
            for candidate in tracked:
                try:
                    if Path("/proc/%s/exe" % candidate).readlink() == binary:
                        os.kill(candidate, 9)
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, default=Path(os.environ.get("MAGPIE_TEST_PROJECT", str(SOURCE))))
    parser.add_argument("--provenance", type=Path, default=DEFAULT_PROVENANCE)
    previous = parser.add_mutually_exclusive_group()
    previous.add_argument("--previous-controller", type=Path)
    previous.add_argument("--previous-fpk", type=Path)
    parser.add_argument("--check-previous", action="store_true", help="verify provenance without starting a service")
    args = parser.parse_args()
    content, info = previous_controller(args.provenance.resolve(), args.previous_controller, args.previous_fpk)
    if args.check_previous:
        print(json.dumps({
            "status": "passed", "previous_version": info["package_version"],
            "controller_sha256": hashlib.sha256(content).hexdigest(),
            "source_fpk_sha256": info["source_fpk"]["sha256"],
            "input": "fpk" if args.previous_fpk is not None else "controller",
        }))
        return
    execute(args.project.resolve(), content, info["package_version"])


if __name__ == "__main__":
    main()
