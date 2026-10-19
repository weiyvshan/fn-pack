#!/bin/bash
set -eu

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
case "$work_dir" in
    /vol*) synthetic_pkgvar="$work_dir/pkgvar" ;;
    *) synthetic_pkgvar="/vol1/sub2api-upgrade-test-$$" ;;
esac
trap 'rmdir -- "$synthetic_pkgvar" 2>/dev/null || true; rm -rf -- "$work_dir"' EXIT HUP INT TERM

TRIM_PKGVAR="$work_dir/var"
TRIM_APPDEST="$work_dir/target"
TRIM_PKGETC="$work_dir/etc"
TRIM_DATA_SHARE_PATHS="$work_dir/share"
TRIM_TEMP_LOGFILE="$work_dir/install-error.log"
export TRIM_PKGVAR TRIM_APPDEST TRIM_PKGETC TRIM_DATA_SHARE_PATHS TRIM_TEMP_LOGFILE

mkdir -p -- "$TRIM_PKGVAR" "$TRIM_PKGETC" "$TRIM_DATA_SHARE_PATHS" "$TRIM_APPDEST/docker/runtime-secrets"

. "$project_dir/cmd/service-setup"

install_log() {
    :
}

assert_mode_600() {
    file="$1"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            return 0
            ;;
    esac
    mode="$(stat -c '%a' "$file")"
    [ "$mode" = "600" ] || {
        printf '%s\n' "Expected mode 600 for $file, got $mode" >&2
        exit 1
    }
}

wizard_admin_email='admin@example.invalid'
wizard_admin_password='AdminPassword123!'
export wizard_admin_email wizard_admin_password

validate_install_credentials
service_preinst
service_postinst

secrets_file="$TRIM_APPDEST/docker/runtime-secrets/.sub2api-secrets"
runtime_secrets_dir="$TRIM_APPDEST/docker/runtime-secrets"
[ -f "$secrets_file" ]
assert_mode_600 "$secrets_file"
grep -Fqx -- 'ADMIN_EMAIL=admin@example.invalid' "$secrets_file"
grep -Fqx -- 'ADMIN_PASSWORD=AdminPassword123!' "$secrets_file"
load_existing_secrets "$secrets_file"
[ -d "$runtime_secrets_dir" ]
assert_mode_600 "$runtime_secrets_dir/database_password"
assert_mode_600 "$runtime_secrets_dir/redis_password"
assert_mode_600 "$runtime_secrets_dir/admin_email"
assert_mode_600 "$runtime_secrets_dir/admin_password"
assert_mode_600 "$runtime_secrets_dir/jwt_secret"
assert_mode_600 "$runtime_secrets_dir/totp_encryption_key"
[ "$(cat "$runtime_secrets_dir/admin_email")" = 'admin@example.invalid' ]
[ "$(cat "$runtime_secrets_dir/admin_password")" = 'AdminPassword123!' ]
[ "$(cat "$runtime_secrets_dir/database_password")" = "$(sed -n 's/^DATABASE_PASSWORD=//p' "$secrets_file")" ]

service_postinst
[ "$(cat "$runtime_secrets_dir/admin_password")" = 'AdminPassword123!' ]

upgrade_dir="$work_dir/upgrade"
upgrade_log="$work_dir/upgrade.log"
mkdir -p -- "$upgrade_dir"
cp -- "$secrets_file" "$work_dir/secrets-before-upgrade"

env \
    TRIM_PKGVAR="$synthetic_pkgvar" \
    TRIM_APPDEST="$TRIM_APPDEST" \
    TRIM_PKGETC="$TRIM_PKGETC" \
    TRIM_DATA_SHARE_PATHS="$TRIM_DATA_SHARE_PATHS" \
    TRIM_TEMP_LOGFILE="$upgrade_log" \
    TRIM_TEMP_UPGRADE_FOLDER="$upgrade_dir" \
    TRIM_APPNAME='sub2api' \
    TRIM_APP_STATUS='upgrade' \
    USER='sub2api' \
    GROUP='sub2api' \
    bash "$project_dir/cmd/upgrade_init"

backup_file="$upgrade_dir/sub2api-runtime-secrets/.sub2api-secrets"
[ -f "$backup_file" ]
cmp -- "$work_dir/secrets-before-upgrade" "$backup_file"
assert_mode_600 "$backup_file"
! grep -Fq -- 'AdminPassword123!' "$upgrade_log"

rm -rf -- "$runtime_secrets_dir"
mkdir -p -- "$runtime_secrets_dir"

env \
    TRIM_PKGVAR="$synthetic_pkgvar" \
    TRIM_APPDEST="$TRIM_APPDEST" \
    TRIM_PKGETC="$TRIM_PKGETC" \
    TRIM_DATA_SHARE_PATHS="$TRIM_DATA_SHARE_PATHS" \
    TRIM_TEMP_LOGFILE="$upgrade_log" \
    TRIM_TEMP_UPGRADE_FOLDER="$upgrade_dir" \
    TRIM_APPNAME='sub2api' \
    TRIM_APP_STATUS='upgrade' \
    USER='sub2api' \
    GROUP='sub2api' \
    bash "$project_dir/cmd/upgrade_callback"

cmp -- "$work_dir/secrets-before-upgrade" "$secrets_file"
[ "$(cat "$runtime_secrets_dir/admin_email")" = 'admin@example.invalid' ]
[ "$(cat "$runtime_secrets_dir/admin_password")" = 'AdminPassword123!' ]
! grep -Fq -- 'AdminPassword123!' "$upgrade_log"

failure_log="$work_dir/upgrade-failure.log"
if env \
    TRIM_PKGVAR="$synthetic_pkgvar" \
    TRIM_APPDEST="$TRIM_APPDEST" \
    TRIM_PKGETC="$TRIM_PKGETC" \
    TRIM_DATA_SHARE_PATHS="$TRIM_DATA_SHARE_PATHS" \
    TRIM_TEMP_LOGFILE="$failure_log" \
    TRIM_TEMP_UPGRADE_FOLDER='' \
    TRIM_APPNAME='sub2api' \
    TRIM_APP_STATUS='upgrade' \
    USER='sub2api' \
    GROUP='sub2api' \
    bash "$project_dir/cmd/upgrade_init"
then
    printf '%s\n' 'Expected an unavailable upgrade directory to fail.' >&2
    exit 1
fi
grep -Fq -- 'Sub2API upgrade temporary directory is unavailable.' "$failure_log"
if od -An -v -t u1 "$failure_log" | tr -s ' ' '\n' | grep -qx '0'; then
    printf '%s\n' 'Lifecycle failure log contains NUL bytes.' >&2
    exit 1
fi
! grep -Fq -- 'AdminPassword123!' "$failure_log"

missing_dir="$work_dir/missing"
missing_target="$work_dir/missing-target"
mkdir -p -- "$missing_dir" "$missing_target/docker/runtime-secrets"
if (
    TRIM_PKGVAR="$missing_dir"
    TRIM_APPDEST="$missing_target"
    wizard_admin_email='admin@example.invalid'
    unset wizard_admin_password
    export TRIM_PKGVAR TRIM_APPDEST wizard_admin_email
    validate_install_credentials
); then
    printf '%s\n' 'Expected a missing administrator password to fail.' >&2
    exit 1
fi

if (
    TRIM_PKGVAR="$missing_dir"
    TRIM_APPDEST="$missing_target"
    wizard_admin_email='not-an-email'
    wizard_admin_password='AdminPassword123!'
    export TRIM_PKGVAR TRIM_APPDEST wizard_admin_email wizard_admin_password
    validate_install_credentials
); then
    printf '%s\n' 'Expected an invalid administrator email to fail.' >&2
    exit 1
fi

preserved_dir="$work_dir/preserved"
preserved_target="$work_dir/preserved-target"
mkdir -p -- "$preserved_dir" "$preserved_target/docker/runtime-secrets"
cp -- "$secrets_file" "$preserved_dir/.sub2api-secrets"
(
    TRIM_PKGVAR="$preserved_dir"
    TRIM_APPDEST="$preserved_target"
    unset wizard_admin_email wizard_admin_password
    export TRIM_PKGVAR TRIM_APPDEST
    validate_install_credentials
    prepare_runtime_secrets
    [ "$(cat "$preserved_target/docker/runtime-secrets/admin_email")" = 'admin@example.invalid' ]
    [ "$(cat "$preserved_target/docker/runtime-secrets/admin_password")" = 'AdminPassword123!' ]
)

broken_dir="$work_dir/broken"
mkdir -p -- "$broken_dir"
printf '%s\n' 'ADMIN_EMAIL=broken@example.invalid' > "$broken_dir/.sub2api-secrets"
if (
    TRIM_PKGVAR="$broken_dir"
    TRIM_APPDEST="$work_dir/broken-target"
    unset wizard_admin_email wizard_admin_password
    export TRIM_PKGVAR TRIM_APPDEST
    validate_install_credentials
); then
    printf '%s\n' 'Expected incomplete preserved credentials to fail.' >&2
    exit 1
fi

printf '%s\n' 'Sub2API installer credential and upgrade tests passed.'
