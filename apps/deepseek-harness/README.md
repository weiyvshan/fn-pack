# DeepSeek Harness for fnOS

This maintained source tree combines the strongest parts of the two community
fnOS integrations while treating both as implementation evidence rather than
the platform specification.

## Package contract

- App identity: `deepseek-harness`
- Package version (independent fnOS release series): `0.0.20`
- Upstream DSH: `@deepseek-ai/dsh` `0.2.1-rc.2`, built from official release commit `687f282e8625c6b8d11ff58211a90524be2e4317`
- Platform: x86 only; the source runtime is built and tested as Linux x86-64
- Runtime dependency: `nodejs_v24`
- Backend: dynamically selected loopback-only `127.0.0.1` port
- Entry: `/app/deepseek-harness/` through `${TRIM_APPDEST}/app.sock`
- Authorization: NAS session plus explicit `X-Trim-Isadmin: true`
- Persistent state: `${TRIM_PKGHOME}/.dsh`
- Managed shell state: `${TRIM_PKGVAR}/shell` (bash history and XDG state,
  cache, and data directories); it is retained in fnOS `@appdata`, not in the
  apphome root
- Workspace: first path in `TRIM_DATA_SHARE_PATHS`, with `${TRIM_PKGVAR}/workspace` fallback
- Profile package manager: bundled `pnpm` `11.28.5`, exposed only to the DSH process through an application-private launcher
- Filesystem sandbox launcher: official `@deepseek-ai/node-addon-system-linux-x64` `0.1.2` (`bin/landlock-run`), hash-locked and functionally probed during the build
- PTY runtime: upstream `node-pty` `1.2.0-beta.15` with the verified Linux x64 prebuild bundled in `prebuilds/linux-x64/pty.node`
- Bundled skills: `init`, `dsh-maintenance` plus the fnOS/Linux subset of `skill-creator`, sourced from reviewed G480 user skills, shipped read-only under `${TRIM_APPDEST}/builtin-skills`, and exposed through `DSH_BUNDLED_SKILL_DIR`; the `skill-creator` package subset keeps its Markdown references and Bash helpers but excludes PowerShell scripts
- Local source deltas: five ordered, hash-locked patches for fnOS profile-local pnpm stores in the upstream plugin manager, private reverse-proxy browser-authentication handoff, attachment persistence across restricted fnOS volume ancestors, documented Gateway/Connection transport defaults, and the file-upload Agent-resolver release fix that keeps a session controller registrable after a configuration reload (the upstream 4096 MiB TypeScript build heap is kept as-is: 0.2.1-rc.2 host builds no longer fit under a 3072 MiB cap)

The package home is `${TRIM_PKGHOME}` (on the G480 target volume,
`/vol2/@apphome/deepseek-harness`; on the YDYNAS target volume this is
`/vol1/@apphome/deepseek-harness`). The active DSH data root is
`${TRIM_PKGHOME}/.dsh`. The package does not create or remove a system-level
`/home` compatibility link; lifecycle scripts pass `HOME=${TRIM_PKGHOME}` and
`DSH_HOME=${TRIM_PKGHOME}/.dsh` explicitly, so installation does not depend on
write access to `/home`. The package does not edit `/etc/passwd` or make the
service account login-capable. DSH receives `HOME=${TRIM_PKGHOME}` and
`DSH_HOME=${TRIM_PKGHOME}/.dsh`; credentials, profiles, web-auth tokens, and
runtime state are intentionally under the app-visible package home. Existing
user data is left untouched. Upgrade hooks do not migrate or rewrite existing
DSH data.
The upstream managed bash/pwsh terminal always injects `DSH_SHELL=1`; this
identity marker is owned by Harness and is not plugin-configurable. Shell
history and XDG shell state are redirected to `${TRIM_PKGVAR}/shell`, so the
interactive shell does not create retained state such as `.bash_history` under
`${TRIM_PKGHOME}`.

The default DSH workspace remains the first configured data share. The gateway normalizes, resolves,
deduplicates, and existence-checks `TRIM_DATA_SHARE_PATHS`,
`TRIM_DATA_ACCESSIBLE_PATHS`, and `${TRIM_PKGHOME}` before exporting visible
roots, including `${TRIM_PKGVAR}` (`@appdata`) and
`TRIM_DATA_SHARE_PATHS` (`@appshare`). Since `DSH_HOME` is
`${TRIM_PKGHOME}/.dsh`, it is visible through the apphome root by design, but
visibility is not write authorization.

The default `workspace-write` sandbox deliberately keeps the upstream writable
root set: the session workspace and platform temporary directories. It does
not add `${TRIM_PKGHOME}` or `${TRIM_PKGHOME}/.dsh`. A model shell or file tool
that needs to modify `DSH_HOME` must request an explicit higher-risk mode and
receive user authorization; the package does not silently broaden the write
boundary. `read-only` remains fully non-writable.

The TCP service is never configured to listen on `0.0.0.0`. The unified
gateway proxy strips the public prefix, rewrites only built-in and registered
plugin route namespaces, supports WebSocket upgrades, and presents loopback
semantics to DSH only after the fnOS administrator identity has been verified.
It discards browser-supplied provenance headers and then emits a fixed internal
same-origin marker for that authenticated loopback hop. For the bundled
official settings client, the proxy recognizes its exact persistence mirror
shape and enables Host-backed settings only after that administrator gate has
passed. It also disables conditional revalidation for direct or combined
settings bundles so a same-revision browser cache cannot preserve the remote
fallback. Unknown settings bundle shapes remain unchanged. For the bundled
`dsh-plugin-manager` Web client, the proxy also adapts its browser-only
loopback capability check after the administrator gate has passed; this does
not remove the Host-side loopback route fence or change plugin authorization.
For a retained `@linxin666/dsh-remote-web-ui` client or the verified
`@linxin666/dsh-web-all` aggregate that embeds it, the proxy recognizes each
browser module through its exact container ID, effect labels, heartbeat route,
and one uniquely matched supported code shape. Only those responses are
presented as a local desktop: their pairing heartbeat and global remote request
channel remain
inactive, so the plugin cannot redirect other DSH requests through `/remote`
inside the fnOS administrator page. Unknown or changed bundles are returned
unchanged, and neither the installed plugin files nor its Host routes are
modified.
For recognized `dsh-better-sidebar` client and registry modules, the gateway
also repairs the `agent-terminals` and `agent-opens` WebSockets: a successful
connection resets the consecutive-failure counter, a 25-second text heartbeat
keeps the fnOS route active, and close/unmount paths release the interval. Both
known channel shapes must match before this adapter changes a bundle.
For the known `dsh-mobile-ui` `0.1.0-rc.1` browser bundle, the gateway repairs
the package's incorrect scoped `@deepseek-ai/dsh-mobile-ui` registration so it
matches the unscoped `dsh-mobile-ui` Loader row. The adapter requires the
viewport event, bottom-navigation slot, and document attribute markers, works
inside direct or combined plugin responses, and disables conditional
revalidation for those requests. It does not modify the installed plugin and
leaves unknown or already-correct bundle shapes unchanged. The original
upstream package also publishes a CommonJS Host entry under `type: module`;
that separate package defect must be fixed by the plugin build before it can
start on DSH.
This is FPK fnOS integration code, not a DSH core or plugin authorization
mechanism.

## Transport and summary compatibility

The fourth locked source patch changes schema defaults only: Gateway sends WebSocket
Ping control frames every 15 seconds by default, Connection reports a generation
that is still not ready after 10 seconds, and ends that readiness wait at 45
seconds. Explicit Gateway and Connection configuration still overrides those
defaults. Each Gateway-to-backend HTTP upgrade attempt has a 10-second bound; once
upgraded, it relays the WebSocket byte stream without changing framing or the
`remote.mux` protocol. Errors close both sockets immediately. Writes that keep
requesting drain for 45 seconds close the relay; EOF first flushes both queued
write tails within the same 45-second limit. A rejected handshake closes its
client socket after writing the response. Header and queued pre-upgrade client buffers are limited to 64 KiB.

The fifth locked source patch fixes the file-upload Agent-resolver release. A Host
service is reached through a Cordis proxy, and reading a function-valued
property through that proxy returns a fresh wrapper on every access, so the
upload service compared its stored resolver against a different function object
and never released the registration. A configuration reload that re-created the
session controller then failed with `file-upload: Agent resolver is already
registered`, which surfaced in the browser as `sessionController is unavailable`
for every new session while the page itself still loaded. The resolver now lives
in a plain holder object, so the identity comparison holds and the registration
is released with its owner. The upstream regression target
`packages/client/file-upload/tests/file-upload-resolver-release.host.spec.ts`
covers both the release and the late-disposer case.

The package-owned changes-summary compatibility adapter accepts only the reviewed
compiled client shape. It records a missing summary only for an HTTP `404` whose
trimmed body is exactly `Change summary unavailable.`; that negative state has a 60-second
TTL and a strict 256-entry bound. Network failures, HTTP `5xx` responses, and
invalid JSON remain retryable errors rather than permanent missing summaries. The
existing localized retry `Button` remains visible for that error state, uses a
one-second retry backoff, and reset or disposal cancels and isolates the old
connection generation. Cache expiry is checked on later reads or connection
reset; it does not schedule polling. The adapter does not recover summary or
diff contents discarded by the Host's turn recorder. Snapshot size, pagination,
and Session persistence formats are unchanged. Historical HAR captures without
Ping, Pong, or Close frames do not establish heartbeat failure as the cause of
those disconnects.

Official DSH `0.2.1-rc.2` requires a per-process launch token before it issues
its signed browser-session Cookie. The package passes that token to the
administrator-only gateway through an atomic mode-`0600` file. The patched
official Web bundle suppresses native browser opening whenever that managed
token file is configured, so lifecycle startup does not pass a profile-level
`--no-open` option that retained third-party Web bundles may reject. DSH logs
only the clean loopback URL. On the first administrator root request, the
gateway replaces any browser-supplied token with the private value and forwards
DSH's clean `303` plus a path-scoped Cookie. Requests with a missing or rejected
Cookie repeat that exchange; non-administrators never reach it. Stop and
failed-start paths remove the token file.

DSH plugins retain their own business behavior and data. For example,
`dsh-task-board` keeps its host-authoritative ledger at
`${TRIM_PKGHOME}/.dsh/task-board/ledger-v2.json`. fnOS deployments use the
existing authenticated unified gateway; they do not require an additional
nginx or caddy proxy. A separate authenticated reverse proxy is only relevant
when DSH is deliberately deployed outside the fnOS unified gateway.

## Open files and workspaces in fnOS

The gateway injects a small enhancement script (`/__fnos/fnos-open.js`) plus
the vendored fnOS JS SDK (`/__fnos/trim-web-app.js`, bundled from the locked
`@trimjs/web-app` `0.4.2` lock in `app/web/trim-web-app.lock.json`) into the
harness HTML shell, and the manifest declares `micro_app = true` so the
page-routing bridge initializes inside the desktop iframe. In an embedded fnOS
Web desktop, the script takes over the existing "打开" action on every upstream
presented-file card; it does not add a second button. Paths under package data
shares (`TRIM_DATA_SHARE_PATHS`) or fnOS user-authorized roots
(`TRIM_DATA_ACCESSIBLE_PATHS`) are opened directly through the SDK `openFile`
page routing. Anything else (for example a session that changed its working
directory into `.dsh`) is first copied by the
gateway-local `POST /__fnos/export-open` endpoint into
`${DSH_WORKSPACE}/dsh-exports/` with a sanitized, collision-safe name and then
opened from there. The side-panel preview action remains unchanged. The export
endpoint is reachable only through the administrator-gated gateway, resolves
the requested path with `realpath`, and rejects any path outside the data
shares or `DSH_HOME`; standalone browser pages retain the upstream behavior.
The DOM anchors are upstream-defined and may change between releases; every
step degrades silently.

The same gateway-owned script adapts DSH's `/open-in-app/` browser protocol
inside the fnOS desktop iframe. It replaces the Host catalog with the sole
`filemanager` choice and routes it through `openFileManager(path)`; stale VS
Code, Cursor, Zed, or other desktop choices are rejected instead of reaching
the headless NAS Host. During `TrimApp` construction the adapter temporarily
removes the fnOS Web iframe's misleading `FNAppVer` user-agent token so the
locked SDK selects its Web carrier, then restores the original user agent. SDK
readiness is bounded to five seconds so a missing bridge settles as an error
instead of leaving the Session-header control permanently busy. Standalone
browser pages receive an empty local-app catalog. The adapter is shipped inside
`app.tgz` and injected by the gateway on every startup, so fresh installs and
upgrades use the same code path without lifecycle-time patching.

The Session Header's `下载 Session 日志` action and the `/export` command use
the same fnOS adapter. It sends the session ID to the administrator-gated
`POST /__fnos/export-session` endpoint, which obtains the upstream ZIP through
the authenticated local DSH route, validates it, and stores it under
`${DSH_WORKSPACE}/dsh-exports/`. The browser download anchor is then replaced
with `openFileManager` for that generated archive. Session IDs are validated,
the archive is size-limited, and incomplete or non-ZIP responses are discarded.


## Plugin gateway compatibility

The package stores a versioned, profile-scoped registry at
`${TRIM_PKGHOME}/.dsh/gateway-compat.json`. Each plugin entry records its
observed version and approved first-level route namespaces. The proxy consumes
only that registry and reads it again for each proxied response; it never
rewrites arbitrary third-party absolute URLs.

The proxy also derives namespaces for an installed profile dependency only
when its package name appears in the package-reviewed known-root map. For
example, an installed `dsh-better-sidebar` dependency contributes `/sidebar/`
without changing the registry. Removing that dependency removes the derived
namespace on the next response. Arbitrary bundle scanning never grants routes.

Upgrades preserve existing explicit registry entries. An unknown plugin whose
route is constructed dynamically requires a separate administrator-approved
maintenance operation that validates the installed dependency and writes only
lowercase first-level namespaces through `gateway-compat.js`. Refresh the page
after that write; neither the Harness process nor the FPK needs a restart.
The package includes the reviewed G480 `dsh-maintenance` skill and the
fnOS/Linux subset of the reviewed G480 `skill-creator` directory in the DSH
bundled skill root. The former covers gateway route registration, cross-owner
access, and transient frontend/backend readiness failures on fnOS. The latter
keeps `SKILL.md`, both reference documents, and the three Bash helpers; its
three `.ps1` counterparts are deliberately excluded from this Linux-only FPK.
The packaged Bash helpers include the reviewed G480 corrections: invalid
resource kinds fail before creating a skill tree; the Markdown template is
emitted through a quoted heredoc and placeholder substitution; front matter
keys are trimmed before validation; YAML quoting doubles backslashes; and
optional interface values retain embedded semicolons.
The bundled `init` skill creates or incrementally refreshes a repository's
`AGENTS.md`, preserving user-authored instructions. Its document and interface
metadata are reviewed source snapshots from the supplied `init.zip`; malformed
punctuation was normalized before hash-locking. It contains no executable scripts.
These files are source snapshots, so future builds remain offline and do not
depend on OneSSH or the G480 filesystem.
The FPK does not copy, synchronize, delete, or change ACLs below the mutable
`${DSH_HOME}/skills` directory. A user-provided skill with either bundled name
therefore remains an independent override with DSH's documented higher
precedence over the bundled fallback.

Literal paths are rewritten in text responses. Pages also receive a small
runtime adapter for registered namespaces that covers `fetch`, XHR, WebSocket,
and EventSource URLs constructed after page load. Namespaces must match the
lowercase first-level form `/<name>/`; platform paths such as `/app/`, `/api/`,
`/assets/`, `/plugins/`, `/cgi/`, `/webman/`, and `/__fnos/` are never registered.

### dsh-purge on fnOS

The reviewed `dsh-purge` derivative is pinned in
`plugin-locks/dsh-purge.json`; its source delta is
`plugin-patches/0001-dsh-purge-fnos-runtime.patch`. It preserves upstream
`1.3.5` patch behavior while using `TRIM_APPDEST` to locate the packaged DSH
runtime, leaving the fnOS-managed launcher untouched, and replacing the
plugin's detached self-restart with an App Center restart notice. Its Web
settings API requires the approved `/dsh-purge/` gateway namespace. The plugin
archive is a device-side profile dependency and is not bundled into the FPK.

Because the application is gateway-only, the manifest does not declare
`service_port` or `checkport`. Startup allocates a private loopback port,
passes it only through the DSH `--port` option, briefly confirms that DSH
remains alive and answers HTTP throughout a 15-second stability window, and
only then creates the gateway socket. Install and upgrade remove only the exact web profile
generated by affected older revisions; customized profiles are preserved.
Interrupted startup and package upgrade paths clean only PID-verified
application processes.

The stability window distinguishes a backend that exited from a backend that
merely did not answer in time. The readiness probe answers within a one-second
timeout, so a backend that is still busy finishing its startup work can miss
it without being gone; only a missing process is reported as an exit, and a
backend that keeps missing the probe is reported as unresponsive. A failed
startup therefore never stops a backend that is still running and answering:
such a backend is kept, the next start reuses it and repairs only the gateway
proxy, and an interruption after the backend became ready completes the
remaining startup steps instead of aborting. The gateway proxy starts as soon
as the backend answers, so it comes up while the stability window runs
instead of after it.

The backend and the gateway proxy each run in their own process group, and
the stop path signals the whole group instead of a single PID. A child that
the service spawned therefore does not survive a stop. The group is only
signalled when the process leads it, so a signal can never reach the platform
or the lifecycle script, and an installation that was started before the
process group was introduced keeps the single process behaviour.

The package install can hold the data volume read only for a short while. The
runtime state lives in that volume, so the start waits for it to become
writable instead of failing, and a log that cannot be written falls back to
the standard error that the platform captures. A write that cannot happen
never takes the service down, because the shell treats a failed redirection as
a fatal error.

Before DSH starts, the lifecycle wrapper exports a controlled terminal shell:
executable `/bin/bash` is preferred and `/bin/sh` is the fallback. This keeps
plugins that honor `$SHELL` from selecting the fnOS package account's non-login
passwd shell. The package does not make its service account login-capable or
modify `/etc/passwd`; startup fails clearly if neither supported shell exists.

When an application proxy is configured, startup first verifies that the
installed Node runtime supports `--use-env-proxy`, then injects uppercase and
lowercase HTTP(S) proxy variables, `NO_PROXY`/`no_proxy` for
`127.0.0.1,localhost`, and matching `npm_config_proxy`,
`npm_config_https_proxy`, and `npm_config_noproxy` aliases into the DSH process
only. This gives Node fetch, Corepack, pnpm/npm, curl, and Git HTTPS one
process-scoped proxy contract. The private pnpm launcher normalizes inherited
standard variables into missing npm aliases, and the approval-gated official
plugin tool explicitly forwards only those proxy variables alongside its
existing profile isolation environment. The Web plugin console inherits the
same DSH process environment when it invokes Corepack or pnpm. The port selector
and unified gateway proxy do not receive the application proxy environment.
Without a saved proxy, DSH keeps its original command line, does not enable
Node's environment-proxy switch, and neither plugin path synthesizes proxy
variables. No `.npmrc`, `.env`, or system shell profile is written. A proxy
address of `127.0.0.1` refers to the fnOS device itself; for a proxy on another
computer, configure that computer's LAN IP address.

The install wizard values are bootstrap inputs, not the persistent source of
truth. They are consumed only once during a fresh `INSTALL`, after which a
private initialization marker prevents fnOS from replaying stale
`wizard_*` values when it invokes the install callback during an upgrade or a
preserved-data reinstall. The callback also requires the `.dsh` data root to
have been absent when it began, so legacy installations without the marker are
protected even if fnOS reports their upgrade callback as an install operation.
App Center settings continue to update or clear the files below
`${TRIM_PKGHOME}/.dsh`; an upgrade preserves both configured values and an
intentional cleared state.

## Source and runtime separation

Generated `node_modules` are not stored in this source tree. The clean upstream
checkout is prepared by the repository-root `bootstrap.sh` at the ignored
`.tmp/deepseek-harness-upstream` path, detached at the locked commit.
The small `app/server/package.json` checked into this repository is only a
source marker; it is removed from staging and replaced with the complete
source-built production runtime before fnpack runs. Each FPK includes a
deterministic `build-info.json` below the installed application target. It
identifies the independent fnOS package version, upstream DSH version, commit
and tree, the original source marker, and byte size plus SHA-256 for the
package-owned gateway, launchers, runtime manifests, and DSH
entry point. On a typical G480 installation it can be read at
`/vol2/@appcenter/deepseek-harness/build-info.json`, so an installed tree can be
matched to its source build without relying on the mutable data directory or a
missing copy of the outer manifest.
`runtime.lock.json` pins its official repository, commit and tree, upstream
`pnpm-lock.yaml` and CLI manifest hashes, DSH version, pnpm tarball and
integrity, the official linux-x64 Landlock launcher tarball and integrity,
the five fnOS source patches and their upstream test targets, platform, and ELF
machine identifier. The build uses `git archive` for the locked commit, verifies and
applies all five patches in order, and does not consume an upstream or community
FPK.

pnpm is a DSH runtime prerequisite for `dsh plugin`, so the upstream-required
version is packaged in the FPK instead of being installed globally on fnOS.
Profile plugins remain mutable state below `${TRIM_PKGHOME}/.dsh`. Upstream
`plugin_manager` owns install, update, remove, rollback, build-script approval,
compatibility checks, registry fallback, cancellation, and live reload. Gateway
compatibility is intentionally separate: reviewed known roots are derived only
when an installed dependency key matches its package manifest identity, while
explicit registry entries are preserved.
The FPK contains only the official DSH production runtime and does not seed
third-party Web UI plugins on a fresh installation. Upgrade hooks stop
package-owned processes, validate the newly installed runtime, and recreate
only missing launcher/state directories; they do not migrate, back up, or
rewrite user profiles, settings, credentials, or plugin data.
Install and upgrade atomically publish a mode-`0700` administrator entry at
`${TRIM_PKGVAR}/bin/dsh` (on the G480 installation this is
`/vol2/@appdata/deepseek-harness/bin/dsh`). It fixes the application target,
private data directory, Node.js 24 runtime, and a controlled `PATH`, replacing
temporary device-side launcher edits from earlier revisions.

The private launcher sets `DSH_FNOS_PLUGIN_POLICY=1`. Under that marker, every
upstream CLI or `plugin_manager` package operation receives
`DSH_PLUGIN_STORE_DIR=<profile>/.pnpm-store` and the matching
`pnpm_config_store_dir`; the package-managed pnpm launcher rejects empty,
non-canonical, cross-profile, and symlink-crossing store paths. If
`node_modules/.modules.yaml` still names the former application-global store,
the first mutating operation runs `pnpm install --force` under the same profile
lock, environment, bounded-output, cancellation, and process-tree controls,
verifies that pnpm relinked to the private store, and only then runs the requested
operation. A read-only `list` never triggers migration. A failed migration
restores the managed manifest and lockfile and does not run the requested mutation.

The model-facing tool is upstream `plugin_manager`, not the removed fnOS
`dsh_plugin` tool. CLI, Web, and agent operations share upstream's transaction,
compatibility, approval, rollback, cancellation, and reload paths. The fnOS
patch does not reintroduce hard-coded `allowBuilds`, package overrides,
cross-profile writes, or a parallel package-management implementation.

The root `dsh-browser` package is not a standard Harness plugin: it declares no
`dsh.bundle`, and its installer assumes desktop Chrome plus the macOS `pbcopy`
and `open` commands. The actual bridge package is nested below its monorepo, so
installing the root package through `dsh plugin` only creates a plain profile
dependency and cannot provide the advertised fnOS workflow. Package upgrades
do not silently remove existing dependencies. A mistaken G480 `dsh-browser`
dependency must be removed later through a separately approved remove action;
other plugins, bundle order, lockfiles, and the profile-local store must be
verified around that operation.

The source build runs directly on x86-64 fnOS/Debian with Node.js 22.19 or
newer, GCC, Make, Python 3, `readelf`, and Git. From the repository root, run:

```bash
bash bootstrap.sh
```

The bootstrap script prepares `.tmp/deepseek-harness-upstream` and passes it
explicitly to the source resolver. Missing locked pnpm and Landlock archives are
downloaded into `.tmp/deepseek-harness-runtime-cache`; cached and downloaded
archives must both pass SHA-256 and SHA-512 integrity checks. Neither the upstream
checkout nor downloaded archives are committed to Git.

With an already prepared checkout and cached assets, an offline asset build can
also be requested explicitly (the source build may still require other npm dependencies):

```bash
bash apps/deepseek-harness/scripts/build-fpk.sh \
  --source-tree .tmp/deepseek-harness-upstream \
  --pnpm-tarball .tmp/deepseek-harness-runtime-cache/pnpm-11.28.5.tgz \
  --landlock-tarball .tmp/deepseek-harness-runtime-cache/node-addon-system-linux-x64-0.1.2.tgz
```

`--source-tree` remains an explicit CI and diagnostic override, but the supplied
checkout must have the locked origin, commit and tree and a clean working tree.
Alternatively, with the checkout prepared by bootstrap, `--allow-download`
downloads missing pnpm and official Landlock launcher archives into the ignored
cache:

```bash
bash apps/deepseek-harness/scripts/build-fpk.sh \
  --source-tree .tmp/deepseek-harness-upstream --allow-download
```

The Linux build and validation chain requires only the native `.sh`, Node.js,
and Python entry points. It neither invokes nor checks for `pwsh`; the retained
`.ps1` wrappers are Windows-only compatibility entry points.

## Line endings

The repository keeps every tracked text file in LF. The package is built and run
on Linux, and the locked upstream source patches are applied with `git apply`,
which requires LF bytes, so a CRLF working tree breaks the build before it
starts.

The repository root carries a `.gitattributes` that marks text files as
`text=auto eol=lf` and pins the binary payloads as `binary`. The `eol=lf`
attribute takes precedence over a workstation-wide `core.autocrlf=true`, so a
Windows checkout materialises the same LF bytes as a Linux one. The Git index
always stores LF as well, because the same attributes normalise the content on
commit.

`apps/deepseek-harness/scripts/check-line-endings.sh` and its PowerShell twin
enforce that rule. Both contract test entry points run the guard, so a CRLF
regression fails the package validation instead of the Linux build. The guard
reads the working tree rather than the index, because the index cannot hold
CRLF once the attributes are in place and the build reads the working tree.

A checkout that already carried CRLF content is repaired with:

```bash
git rm --cached -r . && git reset --hard
```

which re-materialises every tracked file through the attributes.

The submodule is a source archive, not a development worktree. To change
upstream code, create a disposable worktree below `.tmp/`, apply the ordered
patch series, edit and run the upstream tests there, then regenerate and review
the corresponding file in `apps/deepseek-harness/patches/`. A dirty submodule
or explicit source checkout is rejected because uncommitted changes are not
inputs to `git archive` and would otherwise be silently absent from the FPK.

The script archives the verified Git commit, applies the ordered hash-locked
source patches, runs every declared upstream patch target (plugin-manager
operations, Web authentication handoff, attachment storage, Gateway stream,
Connection recovery configuration, and the file-upload Agent-resolver release)
plus the real Linux Landlock confinement suite,
then builds the official pnpm workspace directly on Linux,
recursively closes required workspace dependencies and peers, and deploys a
hoisted production runtime. It removes package-manager `.bin` links and
target-incompatible Windows files before assembling the package runtime.
`node-pty`, Sharp, and `landlock-run` are checked as ELF machine-62
binaries. The launcher must retain executable mode and return a functional
`full` or `partial` Landlock probe before the skill-bundled Linux `fnpack`
builds the FPK.

The final Linux `fnpack` step runs from a temporary native staging tree and
writes into an isolated empty output directory, so lifecycle scripts retain
executable modes, the source-built
runtime retains its Linux archive modes, and a stale unversioned FPK cannot be
mistaken for the current result. The final inspection checks normalized outer
manifest fields, the nested `app.tgz`, source provenance, the generated
device-readable build identity, every recorded component hash, all five
packaged source-patch byte identities, runtime closure, pnpm runtime, both
private-launcher byte identities, Landlock launcher identity and mode, and
absence of an application-root `LICENSE`. The versioned artifact is named
`deepseek-harness_<version>_x86.fpk` and moved into `build/` only after all checks
pass and its byte size and SHA-256 are confirmed
unchanged. Install and upgrade callbacks
still restore the Landlock launcher to `0755` and the private `pnpm`/`dsh`
entries to `0700` defensively; service startup then requires executable
launchers and a successful `full` or `partial` probe. Existing versioned
artifacts are never overwritten.

## Local validation

```bash
PATH=/var/apps/nodejs_v24/target/bin:/usr/local/bin:/usr/bin:/bin \
  bash apps/deepseek-harness/scripts/test-package.sh
bash .agents/skills/fnnas-app-creator/scripts/audit_fnos_project.sh \
  --project-path apps/deepseek-harness --format json
```

The package test runs the native source-checkout resolver suite, all JavaScript
and shell behaviour tests, syntax and line-ending checks, and the same static
audit used before packaging.

## Security boundary

The gateway authenticates the NAS session. This package additionally rejects
non-administrator HTTP and WebSocket requests in application code. It does not
trust visibility controls such as `allUsers=false` as authorization.

API keys are never logged. Wizard input is validated again by lifecycle code,
stored with a restrictive umask, and loaded only from the application-owned
data directory. The optional HTTP proxy accepts no embedded credentials.
Service startup also requires the process UID to match fnOS-provided
`TRIM_UID` before writing persistent state. Administrative cleanup through
`stop` remains available, but `start` and the start half of `restart` must run
through App Center under the package account.

Plugin install sources exposed to an Agent are restricted to npm package
specs, `github:owner/repo#ref` with a mandatory ref, and credential-free HTTPS
tarball URLs. Local paths, `file:`, `link:`, control characters, option
injection, profile traversal, and profile symlinks are rejected before process
creation. Mutations are globally serialized, use a 15-minute default deadline,
remain bounded by explicit timeout overrides, cancellation, and output limits,
and restore the pre-operation profile state on failure. A
failed restoration is reported as `recoveryRequired`; successful changes
return `restartRequired: true` and never restart the responding Harness. A
route-only `gateway` update is separately approved, writes no plugin files,
hot-loads in the proxy, and returns `restartRequired: false`.

## Validation boundary

Local checks cannot prove fnOS gateway routing, Node ABI compatibility, UI
behavior, persistence, or ordinary-user denial on a real NAS. Validate the
final FPK on a dedicated x86 fnOS device before release.

For the proxy path, real-device validation must confirm that the DSH command
line contains `--use-env-proxy`, the DSH environment contains
`NO_PROXY`/`no_proxy`, the configured proxy records
`CONNECT api.deepseek.com:443`, and an actual conversation succeeds while the
fnOS unified gateway and application page remain healthy. Then clear the
application proxy and restart: the DSH command line must no longer contain the
proxy switch, and the proxy must receive no further DSH request.

## Provenance

- DSH upstream: <https://github.com/deepseek-ai/deepseek-harness>
- Runtime compatibility evidence only: <https://github.com/techysy/deepseek-harness-fnos>
- Unified-gateway design evidence: <https://github.com/YUNXI-fi/DeepSeek-Harness-fnos>
