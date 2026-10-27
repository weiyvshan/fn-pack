#!/bin/bash
# Authoritative package contract test for the Sub2API fnOS package.
#
# POSIX replacement for scripts/test-package.ps1, which now only forwards here.
# Every assertion below must hold before an FPK may be built: the pinned image
# digests, the Compose credential wiring, the lifecycle hooks and the desktop
# entry are all part of the install contract.
set -eu

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

manifest="$project_dir/manifest"
compose="$project_dir/app/docker/docker-compose.yaml"
image_lock="$project_dir/image.lock.json"
entry="$project_dir/app/ui/config"
install_wizard="$project_dir/wizard/install"
outer_resource="$project_dir/config/resource"
inner_resource="$project_dir/app/config/resource"
outer_privilege="$project_dir/config/privilege"
inner_privilege="$project_dir/app/config/privilege"
service_setup="$project_dir/cmd/service-setup"
common="$project_dir/cmd/common"
installer="$project_dir/cmd/installer"
install_init="$project_dir/cmd/install_init"
install_callback="$project_dir/cmd/install_callback"
main_hook="$project_dir/cmd/main"
container_entrypoint="$project_dir/app/docker/scripts/sub2api-entrypoint.sh"
postgres_healthcheck="$project_dir/app/docker/scripts/postgres-healthcheck.sh"
license="$project_dir/app/LICENSE"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for required in \
    "$manifest" "$compose" "$image_lock" "$entry" "$install_wizard" \
    "$outer_resource" "$inner_resource" "$outer_privilege" "$inner_privilege" \
    "$service_setup" "$common" "$installer" "$install_init" "$install_callback" \
    "$main_hook" "$container_entrypoint" "$postgres_healthcheck" "$license"
do
    [ -f "$required" ] || fail "missing packaging input: $required"
done

# PowerShell -match/-notmatch are case-insensitive. Porting them as
# case-sensitive greps would silently weaken the contract, so keep -i.
match_re() { grep -Eqi -- "$2" "$1" || fail "$3"; }
reject_re() { if grep -Eqi -- "$2" "$1"; then fail "$3"; fi; }
match_lit() { grep -Fqi -- "$2" "$1" || fail "$3"; }
reject_lit() { if grep -Fqi -- "$2" "$1"; then fail "$3"; fi; }

# The same contract against an extracted excerpt held in a shell variable.
match_text() { printf '%s\n' "$1" | grep -Fqi -- "$2" || fail "$3"; }
reject_text() { if printf '%s\n' "$1" | grep -Fqi -- "$2"; then fail "$3"; fi; }

# --- manifest ---------------------------------------------------------------
match_re "$manifest" '^[[:space:]]*version[[:space:]]*=[[:space:]]*1\.19[[:space:]]*$' \
    'Manifest version must be 1.19.'
match_re "$manifest" '^[[:space:]]*service_port[[:space:]]*=[[:space:]]*18081[[:space:]]*$' \
    'Manifest service port must be 18081.'
# fnpack computes the outer checksum from app.tgz during the build. A
# hand-authored value in the source manifest is a stale duplicate, so its
# absence is part of the contract.
reject_re "$manifest" '^[[:space:]]*checksum[[:space:]]*=' \
    'The source manifest must not hand-author checksum; fnpack owns that field.'
# A semicolon inside a manifest value is treated as a comment introducer by
# fnpack, which truncates the value and re-emits the remainder as a stray
# comment line. Keep the source manifest free of them.
reject_lit "$manifest" ';' \
    'The source manifest must not contain a semicolon, which fnpack parses as a comment.'

# --- pinned images ----------------------------------------------------------
python3 - "$image_lock" <<'PY' || fail 'image.lock.json does not match the reviewed registry metadata.'
import json
import re
import sys

EXPECTED = {
    "sub2api": {
        "repository": "docker.io/weishaw/sub2api",
        "tag": "0.2.18",
        "manifest_digest": "sha256:468a0b0e541e4becc05f1cf57826159235ea27a49a09f3dc2da6a43fcc05a22d",
        "source_repository": "https://github.com/Wei-Shaw/sub2api",
        "source_commit": "ac1b8f1271be0d674fa6f074403c1410f30a3a81",
        "source_version": "0.2.18",
        "platforms": {
            "linux/amd64": "sha256:2bb343e9a3612251acaa5de81ab46ea281f0ea344af8f0596e2ac1989d5bdff4",
            "linux/arm64": "sha256:c97aec3dca03f4cbf657baa1bed3cdf190d9bf0f6515bc5e4bb254bd25c248a2",
        },
    },
    "postgres": {
        "repository": "docker.io/library/postgres",
        "tag": "18-alpine",
        "manifest_digest": "sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2",
        "source_repository": "https://github.com/docker-library/postgres",
        "source_commit": "e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc",
        "source_version": "18.6-alpine3.24",
        "platforms": {
            "linux/amd64": "sha256:63bdc97d67b5133bf0e5ebd500bec6d046fa851dc81340d838f0347e616107e8",
            "linux/arm64/v8": "sha256:cbe15165195f7f2d63885b4d990fdec7b602248533cb05bd992284a45a58fed3",
        },
    },
    "redis": {
        "repository": "docker.io/library/redis",
        "tag": "8-alpine",
        "manifest_digest": "sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241",
        "source_repository": "https://github.com/redis/docker-library-redis",
        "source_commit": "0a24b09f88a6cb8feaf130d4eca7bd6b9b4c73a3",
        "source_version": "8.10.0-alpine",
        "platforms": {
            "linux/amd64": "sha256:a6a88248ad5b0c724b7f2b380b7d21f46097db158b2b077ef85bcb97f90aee3a",
            "linux/arm64/v8": "sha256:0f8941c253cc39d98439a608dcb4f0a840b54421cc5109a68c72b2d2d223cea5",
        },
    },
}


def die(message):
    raise SystemExit("FAIL: " + message)


with open(sys.argv[1], encoding="utf-8") as handle:
    lock = json.load(handle)

if lock.get("schema_version") != 1:
    die("image.lock.json must use schema 1.")
if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(lock.get("resolved_at", ""))):
    die("image.lock.json must contain an ISO resolution date.")

images = lock.get("images") or {}
if set(images) != set(EXPECTED):
    die("image.lock.json must contain exactly the three Compose service images.")

for name, want in EXPECTED.items():
    got = images[name]
    for field in ("repository", "tag", "manifest_digest"):
        if got.get(field) != want[field]:
            die("the %s image lock does not match the reviewed registry manifest (%s)." % (name, field))
    reference = "%s:%s@%s" % (want["repository"], want["tag"], want["manifest_digest"])
    if got.get("reference") != reference:
        die("the %s image reference must be derived from its repository, tag, and manifest digest." % name)
    source = got.get("source") or {}
    if (source.get("repository"), source.get("commit"), source.get("version")) != (
        want["source_repository"],
        want["source_commit"],
        want["source_version"],
    ):
        die("the %s source mapping does not match the reviewed image metadata." % name)
    platforms = got.get("platform_manifests") or {}
    if set(platforms) != set(want["platforms"]):
        die("the %s platform manifest set contains unexpected entries." % name)
    for platform, digest in want["platforms"].items():
        if platforms.get(platform) != digest:
            die("the %s %s manifest does not match the reviewed registry index." % (name, platform))

sub2api_source = images["sub2api"]["source"]
if sub2api_source.get("ref") != "refs/tags/v0.2.18":
    die("the Sub2API source mapping must retain refs/tags/v0.2.18.")
if sub2api_source.get("tag_object") != "de86961b627e48db75d61fff8c05535d44a00cbe":
    die("the Sub2API source mapping must retain the reviewed annotated tag identity.")
PY

# The three PS assertions (locked reference present, no stale mirror, every
# image carries a digest) collapse into one set equality, which also rejects
# any Composable image line that the lock does not account for.
python3 - "$image_lock" "$compose" <<'PY' || fail 'Compose does not use the locked image references.'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    lock = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    compose = handle.read()

expected = sorted(image["reference"] for image in lock["images"].values())
actual = sorted(match.group(1) for match in re.finditer(r"^[ \t]*image:[ \t]*(\S+)[ \t]*$", compose, re.M))

for reference in actual:
    if "docker.1ms.run" in reference:
        raise SystemExit("FAIL: Compose must not hard-code the stale third-party mirror.")
    if "@sha256:" not in reference:
        raise SystemExit("FAIL: every Compose image must include an immutable manifest digest: " + reference)
if actual != expected:
    raise SystemExit(
        "FAIL: Compose image references must be exactly the locked digests:\n  compose=%r\n  lock=%r"
        % (actual, expected)
    )
PY

# --- compose ----------------------------------------------------------------
match_lit "$compose" '${TRIM_SERVICE_PORT}:8080' \
    'Compose must map TRIM_SERVICE_PORT to container port 8080.'
reject_re "$compose" '[$][{](DATABASE_PASSWORD|POSTGRES_PASSWORD|REDIS_PASSWORD|ADMIN_EMAIL|ADMIN_PASSWORD|JWT_SECRET|TOTP_ENCRYPTION_KEY)[}]' \
    'Compose must not depend on credentials patched after Docker project parsing.'
match_lit "$compose" '${TRIM_APPDEST}/docker/runtime-secrets:/run/sub2api-secrets:ro' \
    'Every service must receive credentials from the packaged private runtime directory.'
# The PostgreSQL password file must live inside the very directory the services
# bind-mount read-only; deriving it from the mount keeps this assertion free of
# any hard-coded credential path.
secrets_dir=$(sed -n 's|.*/docker/runtime-secrets:\([^:]*\):ro.*|\1|p' "$compose" | head -n 1 | tr -d '[:space:]')
[ -n "$secrets_dir" ] ||
    fail 'Compose must bind-mount the prepared runtime-secrets directory read-only.'
postgres_password_file=$(sed -n 's/^[[:space:]]*POSTGRES_PASSWORD_FILE:[[:space:]]*//p' "$compose" | head -n 1 | tr -d '[:space:]')
[ "$postgres_password_file" = "$secrets_dir/database_password" ] ||
    fail "PostgreSQL must read its password from the prepared runtime file (found: $postgres_password_file)."
match_lit "$compose" 'postgres-healthcheck.sh' \
    'PostgreSQL health must reconcile a retained database before Sub2API starts.'
match_lit "$compose" '/var/apps/sub2api/shares/sub2api/data:/sub2api-app-data' \
    'PostgreSQL reconciliation must inspect the retained setup state through the declared application data share.'
match_lit "$compose" 'cat /run/sub2api-secrets/redis_password' \
    'Redis must read its password from the prepared runtime file.'
match_lit "$compose" 'sub2api-entrypoint.sh' \
    'Sub2API must use the credential-loading entrypoint wrapper.'
reject_re "$compose" 'wizard_(service_port|runtime_secret|admin_password|admin_email)' \
    'Compose must not depend directly on install-wizard variables.'

# --- desktop entry and install wizard ---------------------------------------
match_re "$entry" '"port"[[:space:]]*:[[:space:]]*"18081"' \
    'Desktop entry port must be 18081.'
reject_lit "$install_wizard" 'wizard_service_port' \
    'The fixed service port must not be exposed as a conflicting wizard field.'

python3 - "$install_wizard" <<'PY' || fail 'The install wizard does not collect a valid administrator identity.'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    wizard = json.load(handle)

items = [item for step in wizard for item in step.get("items", [])]
fields = [item.get("field") for item in items]
for required in ("wizard_admin_email", "wizard_admin_password"):
    if required not in fields:
        raise SystemExit("FAIL: install wizard must collect " + required + ".")

password_items = [item for item in items if item.get("field") == "wizard_admin_password"]
if len(password_items) != 1 or password_items[0].get("type") != "password":
    raise SystemExit("FAIL: administrator password must use a single password-type wizard field.")

patterns = [rule.get("pattern") for rule in password_items[0].get("rules", []) if rule.get("pattern")]
expected = ["^[A-Za-z0-9._~!@%^+=,:-]{12,72}$"]
if patterns != expected:
    raise SystemExit(
        "FAIL: the wizard password pattern must mirror the 12-72 character lifecycle bound: " + repr(patterns)
    )
PY

# --- lifecycle hooks --------------------------------------------------------
match_lit "$service_setup" 'validate_install_credentials' \
    'Lifecycle must validate administrator credentials at the consumption boundary.'
match_lit "$service_setup" 'ADMIN_EMAIL="${wizard_admin_email}"' \
    'Fresh install must use the administrator email selected in the wizard.'
match_lit "$service_setup" 'ADMIN_PASSWORD="${wizard_admin_password}"' \
    'Fresh install must use the administrator password selected in the wizard.'
reject_lit "$service_setup" 'ADMIN_PASSWORD="${wizard_admin_password:-$(generate_password' \
    'Fresh install must not silently replace a missing administrator password.'
match_lit "$install_init" 'validate_install_credentials || exit 1' \
    'Install init must reject invalid administrator credentials.'
match_lit "$install_callback" 'validate_install_credentials || exit 1' \
    'Install callback must reject invalid administrator credentials.'

# The password bound follows upstream 0.2.14, which rejects anything above 72
# bytes because bcrypt truncates. A wizard field or lifecycle check that still
# allows 73-128 characters would accept a password the server then refuses.
# Scope the check to the administrator validator: the runtime secret helper
# legitimately keeps its own 32-128 bound.
admin_password_validator=$(sed -n '/^is_valid_admin_password()/,/^}/p' "$service_setup")
[ -n "$admin_password_validator" ] ||
    fail 'cmd/service-setup must define is_valid_admin_password.'
match_text "$admin_password_validator" '[ "$length" -le 72 ]' \
    'Administrator passwords must be rejected above the upstream 72-byte bound.'
reject_text "$admin_password_validator" '[ "$length" -le 128 ]' \
    'Administrator password validation must not retain the superseded 128-byte bound.'
reject_text "$admin_password_validator" '[ "$length" -ge 8 ]' \
    'Administrator password validation must not retain the superseded 8-byte floor.'

# Install init must not mutate the device before the wizard has run, so the
# pre-install hook has to stay an explicit no-op.
service_preinst_body=$(sed -n '/^service_preinst()/,/^}/p' "$service_setup" | tr -d '[:space:]')
[ "$service_preinst_body" = 'service_preinst(){:}' ] ||
    fail 'Install init must remain read-only for a clean package-user installation.'
match_lit "$service_setup" 'RUNTIME_SECRETS_DIR="${TRIM_APPDEST}/docker/runtime-secrets"' \
    'Lifecycle must use the prepackaged bind directory that exists before Docker project creation.'
match_lit "$service_setup" 'write_runtime_secret_files' \
    'Install callback must materialize runtime credentials before Docker starts.'
match_lit "$service_setup" 'service_save()' \
    'Upgrade init must preserve the private runtime credentials before replacing the target tree.'
match_lit "$service_setup" 'service_restore()' \
    'Upgrade callback must restore private runtime credentials into the new target tree.'
match_lit "$service_setup" 'local runtime_secrets_dir="${TRIM_APPDEST}/docker/runtime-secrets"' \
    'Upgrade phases must resolve their credential path independently.'
match_lit "$service_setup" 'chmod 600 "$temporary"' \
    'Runtime credentials must be restricted to mode 0600 before atomic replacement.'
reject_re "$service_setup" 'patch_compose_secrets|write_app_env' \
    'Lifecycle must not rely on late Compose patching or app_env transaction visibility.'

match_re "$installer" 'run_phase\(\)' \
    'Installer must capture lifecycle output without sharing an open descriptor with TRIM_TEMP_LOGFILE.'
match_lit "$installer" 'local capture_file="${log_file}.phase.$$"' \
    'Lifecycle output must use a private capture file.'
for wrapper in \
    "$project_dir/cmd/install_init" "$project_dir/cmd/install_callback" \
    "$project_dir/cmd/upgrade_init" "$project_dir/cmd/upgrade_callback" \
    "$project_dir/cmd/uninstall_init" "$project_dir/cmd/uninstall_callback" \
    "$project_dir/cmd/config_init" "$project_dir/cmd/config_callback"
do
    [ -f "$wrapper" ] || fail "missing lifecycle phase wrapper: $wrapper"
    name=$(basename -- "$wrapper")
    match_lit "$wrapper" 'run_phase "$(basename "$0")"' \
        "$name must use the safe lifecycle capture helper."
    reject_re "$wrapper" 'TRIM_TEMP_LOGFILE.*2>&1' \
        "$name must not redirect directly to a log file that error handlers can truncate."
done

# --- container entrypoint wrapper -------------------------------------------
match_lit "$container_entrypoint" 'exec /app/docker-entrypoint.sh "$@"' \
    'The wrapper must preserve the upstream image entrypoint.'
match_lit "$container_entrypoint" 'read_required_secret admin_password' \
    'The wrapper must load the administrator password from the runtime file.'
match_lit "$container_entrypoint" '/app/data/.fnos-secrets' \
    'JWT and TOTP credentials must persist only after the application data mount is available.'
match_lit "$container_entrypoint" 'persist_or_reuse_secret jwt_secret' \
    'The wrapper must reuse the retained JWT credential.'
match_lit "$container_entrypoint" 'persist_or_reuse_secret totp_encryption_key' \
    'The wrapper must reuse the retained TOTP credential.'
reject_re "$container_entrypoint" 'cat .*password.*(echo|printf)' \
    'The wrapper must not log credential contents.'

# --- PostgreSQL reconciliation helper ----------------------------------------
match_lit "$postgres_healthcheck" 'ALTER ROLE' \
    'PostgreSQL health must reconcile the retained database role credential.'
match_lit "$postgres_healthcheck" '.sub2api-database-password.sha256' \
    'PostgreSQL credential reconciliation must use a persistent idempotency marker.'
match_lit "$postgres_healthcheck" "to_regclass('public.users')" \
    'Stale setup repair must first prove the users table exists.'
match_lit "$postgres_healthcheck" 'SELECT count(*) FROM users' \
    'Stale setup repair must prove that the retained user database is empty.'
match_lit "$postgres_healthcheck" '.fnos-stale-setup-backup' \
    'Stale setup blockers must be archived recoverably instead of deleted.'
match_re "$postgres_healthcheck" 'config\.yaml .installed' \
    'Only the two upstream setup blocker files may be archived.'
reject_re "$postgres_healthcheck" 'rm .*config\.yaml|rm .*\.installed' \
    'Stale upstream setup state must never be destroyed.'
reject_re "$postgres_healthcheck" 'set -x|echo .*password' \
    'PostgreSQL credential reconciliation must not log credential contents.'

# --- shared lifecycle helpers -----------------------------------------------
match_lit "$main_hook" 'all_containers_running' \
    'Lifecycle status must validate the complete Compose project.'
match_lit "$common" 'INST_ETC="${TRIM_PKGETC:' \
    'Installer configuration must use the fnOS-supplied package etc path.'
match_lit "$common" 'TRIM_DATA_SHARE_PATHS' \
    'Installer share paths must come from the fnOS data-share contract.'
reject_lit "$common" '/var/apps/${TRIM_APPNAME}' \
    'Lifecycle scripts must not reconstruct fnOS package paths.'
reject_lit "$installer" '/var/apps/${TRIM_APPNAME}' \
    'Lifecycle scripts must not reconstruct fnOS package paths.'

# --- packaged license -------------------------------------------------------
# The LICENSE ships byte-for-byte as committed, and the repository normalises
# every text file to LF, so the expected value is the hash of upstream's LF
# text. Compare it directly: normalising first would let a CRLF checkout pass
# even though the packaged bytes had been rewritten.
license_hash=$(sha256sum "$license" | awk '{print $1}')
[ "$license_hash" = 'a5681bf9b05db14d86776930017c647ad9e6e56ff6bbcfdf21e5848288dfaf1b' ] ||
    fail "The Sub2API LICENSE does not match upstream v0.2.18: $license_hash"

# --- outer and packaged declarations ----------------------------------------
cmp -s "$outer_resource" "$inner_resource" ||
    fail 'Outer and packaged resource declarations must match.'
cmp -s "$outer_privilege" "$inner_privilege" ||
    fail 'Outer and packaged privilege declarations must match.'

python3 - "$outer_resource" "$outer_privilege" <<'PY' || fail 'Outer declarations are not valid fnOS JSON or do not isolate the package user.'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    privilege = json.load(handle)

if (privilege.get("defaults") or {}).get("run-as") != "package":
    raise SystemExit("FAIL: Sub2API lifecycle scripts must remain isolated as the package user.")
PY

printf 'Sub2API package contract tests passed.\n'
