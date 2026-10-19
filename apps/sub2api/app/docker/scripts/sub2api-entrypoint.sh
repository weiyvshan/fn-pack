#!/bin/sh
set -eu

secret_dir=/run/sub2api-secrets
persistent_secret_dir=/app/data/.fnos-secrets

read_required_secret() {
    name="$1"
    path="${secret_dir}/${name}"
    if [ ! -r "$path" ]; then
        printf '%s\n' "Missing required Sub2API runtime credential: ${name}" >&2
        exit 1
    fi
    value=$(cat "$path")
    if [ -z "$value" ]; then
        printf '%s\n' "Empty required Sub2API runtime credential: ${name}" >&2
        exit 1
    fi
    printf '%s' "$value"
}

persist_or_reuse_secret() {
    name="$1"
    supplied_value="$2"
    path="${persistent_secret_dir}/${name}"
    temporary="${path}.tmp.$$"
    if [ -f "$path" ]; then
        value=$(cat "$path")
        if [ -z "$value" ]; then
            printf '%s\n' "Empty persistent Sub2API credential: ${name}" >&2
            exit 1
        fi
        printf '%s' "$value"
        return 0
    fi
    umask 077
    if ! printf '%s' "$supplied_value" > "$temporary"; then
        rm -f "$temporary"
        printf '%s\n' "Cannot persist Sub2API credential: ${name}" >&2
        exit 1
    fi
    chmod 600 "$temporary"
    mv -f "$temporary" "$path"
    printf '%s' "$supplied_value"
}

DATABASE_PASSWORD=$(read_required_secret database_password)
REDIS_PASSWORD=$(read_required_secret redis_password)
ADMIN_EMAIL=$(read_required_secret admin_email)
ADMIN_PASSWORD=$(read_required_secret admin_password)
JWT_SECRET=$(read_required_secret jwt_secret)
TOTP_ENCRYPTION_KEY=$(read_required_secret totp_encryption_key)
mkdir -p "$persistent_secret_dir"
chmod 700 "$persistent_secret_dir"
JWT_SECRET=$(persist_or_reuse_secret jwt_secret "$JWT_SECRET")
TOTP_ENCRYPTION_KEY=$(persist_or_reuse_secret totp_encryption_key "$TOTP_ENCRYPTION_KEY")
export DATABASE_PASSWORD REDIS_PASSWORD ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY

exec /app/docker-entrypoint.sh "$@"
