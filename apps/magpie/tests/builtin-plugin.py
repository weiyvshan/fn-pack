#!/usr/bin/env python3
"""Builtin plugin smoke; run in run-isolated.sh's non-root network namespace.

Unlike the older binary-only fixtures, this copies the COMPLETE prepared app.
No downloads, builds, installed fnOS paths, host users or NSS changes are used.
"""
import argparse
import http.cookiejar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

SOURCE = Path(__file__).resolve().parents[1]
KEY = "builtin-plugin-isolated-test-key"


def check(ok, message):
    if not ok:
        raise AssertionError(message)
    print("PASS " + message, flush=True)


class FakeProvider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.respond({"object": "list", "data": [{"id": "canary", "object": "model", "owned_by": "isolated-test"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.received.put(body)
        self.respond({"id": "chatcmpl-isolated", "object": "chat.completion", "model": "canary",
                      "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
                      "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}})


def execute(project):
    check(os.getuid() != 0, "lifecycle executes as non-root package user")
    host = os.environ.get("MAGPIE_TEST_HOST_NETNS")
    check(host and os.readlink("/proc/self/ns/net") != host,
          "network namespace differs from host")
    check({name for _, name in socket.if_nameindex()} == {"lo"},
          "only loopback exists: bundled runtime works offline")
    for name in ("bin/magpie", "bin/bun", "plugins/magpie-plugin/package.json",
                 "plugins/magpie-plugin/page/personas.js"):
        check((project / "app" / name).is_file(), "prepared app includes " + name)
    with tempfile.TemporaryDirectory(prefix="mgbuiltin.") as folder:
        root = Path(folder)
        target = root / "target"
        shutil.copytree(project / "app", target)
        for name in ("magpie", "bun"):
            (target / "bin" / name).chmod(0o755)
        state = root / "apps/magpie/var"
        for path in (state, root / "etc", root / "tmp", root / "home"):
            path.mkdir(parents=True)
        binary, bun = target / "bin/magpie", target / "bin/bun"
        plugin = target / "plugins/magpie-plugin"
        main = project / "cmd/main"
        registry = state / "xdg/config/magpie/plugins.json"
        marker = state / ".builtin-agent-purge-registered"
        pid_file = state / "run/web.pid"
        env = dict(os.environ)
        env.update({
            "TRIM_APPDEST": str(target), "TRIM_PKGVAR": str(state),
            "TRIM_PKGETC": str(root / "etc"), "TRIM_PKGTMP": str(root / "tmp"),
            "TRIM_PKGHOME": str(root / "home"), "TRIM_UID": str(os.getuid()),
            "TRIM_GID": str(os.getgid()), "TRIM_TEMP_LOGFILE": str(root / "tmp/lifecycle.log"),
            "wizard_web_key": KEY,
            # Deliberately hostile inherited values must not reach helpers/daemon.
            "MAGPIE_BUN": "/nonexistent/bun", "AGENT_PURGE_HOME": "/nonexistent/purge",
        })
        cli_env = dict(env, HOME=str(root / "home"), TMPDIR=str(root / "tmp"),
                       XDG_CONFIG_HOME=str(state / "xdg/config"), XDG_CACHE_HOME=str(state / "xdg/cache"),
                       XDG_DATA_HOME=str(state / "xdg/data"), XDG_STATE_HOME=str(state / "xdg/state"),
                       MAGPIE_BUN=str(bun), AGENT_PURGE_HOME=str(state / "agent-purge"),
                       MAGPIE_NO_STATS="1", DO_NOT_TRACK="1")
        cli_env.pop("MAGPIE_ADDR", None)
        tracked = set()
        provider = ThreadingHTTPServer(("127.0.0.1", 0), FakeProvider)
        provider.received = queue.Queue()
        provider_thread = threading.Thread(target=provider.serve_forever, daemon=True)
        provider_thread.start()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                      urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

        def http_request(path, body=None, base="http://127.0.0.1:3430"):
            request = urllib.request.Request(base + path,
                data=None if body is None else json.dumps(body).encode(),
                headers={"Content-Type": "application/json", "Origin": base})
            with opener.open(request, timeout=20) as response:
                return response.read()

        def api(path, body=None):
            return json.loads(http_request(path, body))

        def gateway_sample():
            models = json.loads(http_request("/v1/models", base="http://127.0.0.1:3425"))["data"]
            model = next(row["id"] for row in models if "canary" in row["id"])
            http_request("/v1/chat/completions", {"model": model, "messages": [
                {"role": "system", "content": "Host system"}, {"role": "user", "content": "Hello"}],
                "stream": False}, base="http://127.0.0.1:3425")
            return provider.received.get(timeout=5)

        def bun_pids():
            result = set()
            for proc in Path("/proc").glob("[0-9]*/exe"):
                try:
                    if proc.readlink() == bun:
                        result.add(int(proc.parent.name))
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass
            return result

        def lifecycle(phase, expected=0):
            result = subprocess.run(["/bin/bash", str(main), phase], env=env,
                                    text=True, capture_output=True, timeout=100)
            if pid_file.exists():
                tracked.add(int(pid_file.read_text().strip()))
            check(result.returncode == expected,
                  "%s returns %s: %s" % (phase, expected, result.stderr.strip()))
            if phase == "stop":
                until = time.monotonic() + 5
                while bun_pids() and time.monotonic() < until:
                    time.sleep(0.1)
                check(not bun_pids(), "stop leaves no bundled Bun plugin-host children")
            return result

        def cli(*args):
            result = subprocess.run([str(binary), "plugin", *args], env=cli_env,
                                    capture_output=True, text=True, timeout=30)
            check(result.returncode == 0, "official plugin " + " ".join(args[:2]))
            return result.stdout

        def restart():
            lifecycle("stop")
            lifecycle("start")

        try:
            lifecycle("install_callback")
            configured = subprocess.run([str(binary), "provider", "add", "offline-persona",
                "id=offline-persona", "url=http://127.0.0.1:%s/v1" % provider.server_port,
                "key=isolated-fixture", "models=canary"], env=cli_env,
                capture_output=True, text=True, timeout=30)
            check(configured.returncode == 0, "official CLI configures only the loopback fake provider: " + configured.stderr.strip())
            lifecycle("start")
            entries = json.loads(registry.read_text())["plugins"]
            check(entries == [{"spec": str(plugin)}], "fresh registration is an absolute local spec with no forced options/off")
            st = marker.stat()
            check(st.st_uid == os.getuid() and st.st_gid == os.getgid() and st.st_mode & 0o777 == 0o600,
                  "successful registration marker is package-owned and private")
            check(not (state / "agent-purge/state.json").exists(), "fresh install does not enable persona rewriting")
            process_env = Path("/proc/%s/environ" % pid_file.read_text().strip()).read_bytes().split(b"\0")
            check(("MAGPIE_BUN=" + str(bun)).encode() in process_env and
                  ("AGENT_PURGE_HOME=" + str(state / "agent-purge")).encode() in process_env,
                  "daemon uses bundled Bun and persistent isolated agent-purge home")
            loaded = json.loads(cli("list", "--json"))
            check(any(item.get("spec") == str(plugin) for item in loaded["loaded"]),
                  "official loader actually loads the builtin plugin")
            listing = cli("list")
            check("onRequest" in listing and "Persona" in listing,
                  "official loader discovers actual request hook and Persona page")
            check(not list((state / "xdg/cache").rglob("magpie-bun")), "no Bun runtime download/cache fallback")
            check(not (state / "xdg/config/magpie/plugins/magpie-plugin").exists(),
                  "local registration does not copy the packaged plugin")

            options = {"mode": "append", "persona": "smoke", "inlinePersonas": [
                {"id": "smoke", "name": "Smoke", "text": "Offline persona smoke"}]}
            http_request("/?k=" + KEY)
            page = next(item for item in api("/api/plugin-pages") if item["spec"] == str(plugin))
            page_url = page["url"]
            check(page["title"] == "Persona" and "导入人设" in http_request(page_url).decode(),
                  "daemon serves the registered Persona page")
            for asset in ("app.js", "style.css", "personas.js", "_magpie/bridge.js"):
                check(bool(http_request(urllib.parse.urljoin(page_url, asset))), "plugin page asset is served: " + asset)
            check(gateway_sample()["messages"][0]["content"] == "Host system",
                  "real gateway forwards fresh requests without persona rewriting")
            saved = api("/api/plugin-pages/options", {"spec": str(plugin), "options": options})
            check(saved == options, "plugin page options API persists inline persona and mode")
            check(gateway_sample()["messages"][0]["content"] == "Offline persona smoke\n\nHost system",
                  "real gateway hook rewrites the request captured by the loopback provider")
            time.sleep(1.1)  # The upstream page options API allows one save per second.
            api("/api/plugin-pages/options", {"spec": str(plugin), "options": dict(options, mode="off")})
            check(gateway_sample()["messages"][0]["content"] == "Host system",
                  "page mode off immediately stops rewriting real gateway requests")
            cli("options", "magpie-plugin", json.dumps(options))
            cli("off", "magpie-plugin")
            before = registry.read_bytes()
            restart()
            check(registry.read_bytes() == before, "restart preserves off and inline options byte-for-byte")
            check(json.loads(registry.read_text())["plugins"][0]["off"] is True, "explicit plugin off remains off")
            check(gateway_sample()["messages"][0]["content"] == "Host system",
                  "disabled plugin leaves real gateway requests unchanged after restart")
            # Exercise the shipped hook using the exact bundled Bun, not a mock
            # implementation. No state means no rewrite unless inline opt-in.
            script = root / "request-hook.mjs"
            script.write_text('''import { onRequest } from %s;
const original = {messages:[{role:"system",content:"Host system"},{role:"user",content:"Hello"}]};
const fresh = structuredClone(original);
if (await onRequest(fresh, {protocol:"chat",agent:"codex",options:{}}) !== undefined || JSON.stringify(fresh)!==JSON.stringify(original)) throw Error("fresh rewrites");
const body = structuredClone(original);
const result = await onRequest(body, {protocol:"chat",agent:"codex",options:%s});
if (result.messages[0].content !== "Offline persona smoke\\n\\nHost system") throw Error("inline options ignored");
console.log("fresh off and inline opt-in passed");
''' % (json.dumps(str(plugin / "hooks.js")), json.dumps(options)))
            subprocess.run([str(bun), str(script)], env=cli_env, check=True, timeout=15)
            check(True, "bundled Bun executes fresh no-rewrite and inline request-hook opt-in")
            cli("rm", "magpie-plugin")
            removed = registry.read_bytes()
            restart()
            check(registry.read_bytes() == removed and marker.exists(), "user removal remains removed after restart")
            check(gateway_sample()["messages"][0]["content"] == "Host system",
                  "removed plugin leaves real gateway requests unchanged after restart")
            lifecycle("stop")

            # Before first successful registration, never repair corrupt JSON or
            # clobber an external plugin sharing the installation name.
            marker.unlink()
            for invalid in ('{"plugins":', '{"plugins":{}}',
                            '{"plugins":[{"spec":"example","off":"yes"}]}',
                            '{"plugins":[{"spec":"example","options":[]}]}'):
                registry.write_text(invalid)
                corrupt = registry.read_bytes()
                lifecycle("start", expected=1)
                check(registry.read_bytes() == corrupt and not marker.exists(),
                      "malformed registry stays untouched without success marker")
            # Official Go storage also permits a null or omitted empty list.
            for empty in ({"plugins": None}, {}):
                registry.write_text(json.dumps(empty))
                lifecycle("start")
                check(marker.exists() and json.loads(registry.read_text())["plugins"] == [{"spec": str(plugin)}],
                      "official null/missing empty registry permits first registration")
                lifecycle("stop")
                marker.unlink()
            unrelated = {"spec": str(root / "agent-purge/unrelated-provider"), "off": True,
                         "options": {"sentinel": "preserved", "nested": {"flag": True}}}
            registry.write_text(json.dumps({"plugins": [unrelated]}))
            lifecycle("start")
            registered = json.loads(registry.read_text())["plugins"]
            check(marker.exists() and unrelated in registered and {"spec": str(plugin)} in registered,
                  "parent directory name is not a collision; existing plugin off/options survive registration")
            lifecycle("stop")
            marker.unlink()
            registry.write_text(json.dumps({"plugins": [{"spec": str(root / "external/magpie-plugin"), "off": True, "options": options}]}))
            collision = registry.read_bytes()
            lifecycle("start")
            check(registry.read_bytes() == collision and not marker.exists(), "external same-name plugin is not replaced or marked registered")
            lifecycle("stop")
            registry.write_text('{"plugins":[]}')
            sentinel = root / "sentinel"
            sentinel.write_text("do not alter")
            marker.symlink_to(sentinel)
            lifecycle("start", expected=1)
            check(sentinel.read_text() == "do not alter" and marker.is_symlink(), "marker symlink is rejected without touching its target")
            marker.unlink()
            registry.unlink()
            registry.symlink_to(sentinel)
            lifecycle("start", expected=1)
            check(sentinel.read_text() == "do not alter", "registry symlink is rejected without mutation")
            registry.unlink()
            registry.write_text(json.dumps({"plugins": [{"spec": str(plugin), "off": True, "options": options}]}))
            existing = registry.read_bytes()
            lifecycle("start")
            check(registry.read_bytes() == existing and marker.exists(),
                  "initial adoption preserves an already configured builtin off/options exactly")
            lifecycle("stop")
            marker.unlink()
            # Assert missing runtime fails, even if settings are otherwise fresh.
            bun.rename(bun.with_name("bun.saved"))
            lifecycle("start", expected=1)
            check(not marker.exists(), "missing bundled Bun fails without a success marker")
            print("PASS builtin plugin isolated smoke", flush=True)
        finally:
            provider.shutdown()
            provider.server_close()
            provider_thread.join(timeout=5)
            subprocess.run(["/bin/bash", str(main), "stop"], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=50)
            for pid in tracked | bun_pids():
                try:
                    if Path("/proc/%s/exe" % pid).readlink() in (binary, bun):
                        os.kill(pid, 9)
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(os.environ.get("MAGPIE_TEST_PROJECT", str(SOURCE))))
    execute(parser.parse_args().project.resolve())


if __name__ == "__main__":
    main()
