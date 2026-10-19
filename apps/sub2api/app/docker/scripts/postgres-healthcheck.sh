#!/bin/sh
set -eu

secret_file=/run/sub2api-secrets/database_password
marker_file="${PGDATA}/.sub2api-database-password.sha256"
empty_database_repair_marker="${PGDATA}/.sub2api-empty-database-setup-repaired"
app_data_dir=/sub2api-app-data

pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 || exit 1

if [ ! -r "$secret_file" ]; then
    printf '%s\n' 'PostgreSQL credential file is missing.' >&2
    exit 1
fi

password=$(cat "$secret_file")
if [ -z "$password" ]; then
    printf '%s\n' 'PostgreSQL credential file is empty.' >&2
    exit 1
fi

expected_checksum=$(printf '%s' "$password" | sha256sum | awk '{print $1}')
current_checksum=$(cat "$marker_file" 2>/dev/null || true)

if [ "$current_checksum" != "$expected_checksum" ]; then
    escaped_password=$(printf '%s' "$password" | sed "s/'/''/g")
    printf "ALTER ROLE %s WITH PASSWORD '%s';\n" "$POSTGRES_USER" "$escaped_password" |
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres >/dev/null
    temporary_marker="${marker_file}.tmp.$$"
    umask 077
    printf '%s' "$expected_checksum" > "$temporary_marker"
    chmod 600 "$temporary_marker"
    mv -f -- "$temporary_marker" "$marker_file"
fi

if [ ! -f "$empty_database_repair_marker" ]; then
    users_table_exists=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT CASE WHEN to_regclass('public.users') IS NULL THEN 'false' ELSE 'true' END;")
    if [ "$users_table_exists" = true ]; then
        user_count=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SELECT count(*) FROM users;')
        if [ "$user_count" = 0 ] && { [ -f "${app_data_dir}/config.yaml" ] || [ -f "${app_data_dir}/.installed" ]; }; then
            backup_dir="${app_data_dir}/.fnos-stale-setup-backup"
            timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
            umask 077
            mkdir -p "$backup_dir"
            chmod 700 "$backup_dir"
            for name in config.yaml .installed; do
                source_path="${app_data_dir}/${name}"
                if [ -f "$source_path" ]; then
                    destination="${backup_dir}/${name}.${timestamp}.$$"
                    mv "$source_path" "$destination"
                    chmod 600 "$destination"
                fi
            done
            temporary_repair_marker="${empty_database_repair_marker}.tmp.$$"
            printf 'repaired_at=%s\n' "$timestamp" > "$temporary_repair_marker"
            chmod 600 "$temporary_repair_marker"
            mv -f "$temporary_repair_marker" "$empty_database_repair_marker"
            printf '%s\n' 'Archived stale Sub2API setup state for an empty user database.' >&2
        fi
    fi
fi

pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1
