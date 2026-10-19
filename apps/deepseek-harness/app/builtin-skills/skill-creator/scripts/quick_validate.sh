#!/usr/bin/env bash
# quick_validate.sh - Validate a skill directory (port of quick_validate.py, zero dependencies)
# Usage: bash quick_validate.sh <skill_directory>
set -u

fail() {
    echo "$1"
    exit 1
}

if [ "$#" -ne 1 ]; then
    echo "Usage: bash quick_validate.sh <skill_directory>"
    exit 1
fi

skill_path="$1"

if [ ! -d "$skill_path" ]; then
    fail "SKILL.md not found"
fi

skill_md="$skill_path/SKILL.md"
if [ ! -f "$skill_md" ]; then
    fail "SKILL.md not found"
fi

content="$(head -c 3 "$skill_md")"
[ "$content" = "---" ] || fail "No YAML frontmatter found"

fm="$(awk 'NR==1 { if ($0 != "---") exit 1; next } $0 == "---" { exit } { print }' "$skill_md")"
if [ -z "$fm" ] && ! awk 'NR>1 && $0=="---" { found=1; exit } END { exit !found }' "$skill_md"; then
    fail "Invalid frontmatter format"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
warnings=""
pending_key=""

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        [[:space:]]*|"")
            if [ -n "$pending_key" ]; then
                warnings="$warnings [WARN] field '$pending_key' appears to be multi-line; strict check skipped for it;"
                printf '%s\t%s\n' "$pending_key" "" >> "$tmp"
                pending_key=""
            fi
            continue
            ;;
    esac
    pending_key=""
    case "$line" in
        *:*)
            key="${line%%:*}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${line#*:}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            if [ -z "$value" ]; then
                warnings="$warnings [WARN] field '$key' has no inline value (nested or empty); strict check skipped for it;"
                printf '%s\t%s\n' "$key" "" >> "$tmp"
                continue
            fi
            case "$value" in
                [|\>]*)
                    warnings="$warnings [WARN] field '$key' uses a block scalar; strict check skipped for it;"
                    printf '%s\t%s\n' "$key" "" >> "$tmp"
                    pending_key="$key"
                    continue
                    ;;
            esac
            case "$value" in
                \"*\") value="${value#\"}"; value="${value%\"}" ;;
                \'*\') value="${value#\'}"; value="${value%\'}" ;;
            esac
            printf '%s\t%s\n' "$key" "$value" >> "$tmp"
            ;;
        *)
            warnings="$warnings [WARN] unrecognized frontmatter line: $line;"
            ;;
    esac
done <<EOF
$fm
EOF

get_field() {
    awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$tmp"
}
has_field() {
    awk -F'\t' -v k="$1" '$1 == k { found=1; exit } END { exit !found }' "$tmp"
}

allowed="name description license allowed-tools metadata"
unexpected=""
while IFS=$'\t' read -r k v; do
    case " $allowed " in
        *" $k "*) ;;
        *) unexpected="$unexpected $k" ;;
    esac
done < "$tmp"
unexpected="$(printf '%s\n' $unexpected | sort | uniq | tr '\n' ' ')"
unexpected="${unexpected% }"
if [ -n "$unexpected" ]; then
    fail "Unexpected key(s) in SKILL.md frontmatter: $unexpected. Allowed properties are: name, allowed-tools, description, license, metadata"
fi

if ! has_field name; then
    fail "Missing 'name' in frontmatter"
fi
if ! has_field description; then
    fail "Missing 'description' in frontmatter"
fi

name="$(get_field name)"
if [ -n "$name" ]; then
    case "$name" in
        *[!a-z0-9-]*) fail "Name '$name' should be hyphen-case (lowercase letters, digits, and hyphens only)" ;;
    esac
    case "$name" in
        -*) fail "Name '$name' cannot start/end with hyphen or contain consecutive hyphens" ;;
    esac
    case "$name" in
        *--) fail "Name '$name' cannot start/end with hyphen or contain consecutive hyphens" ;;
    esac
    case "$name" in
        *-) fail "Name '$name' cannot start/end with hyphen or contain consecutive hyphens" ;;
    esac
    if [ "${#name}" -gt 64 ]; then
        fail "Name is too long (${#name} characters). Maximum is 64 characters."
    fi
fi

description="$(get_field description)"
if [ -n "$description" ]; then
    case "$description" in
        *"<"*|*">"*) fail "Description cannot contain angle brackets" ;;
    esac
    if [ "${#description}" -gt 1024 ]; then
        fail "Description is too long (${#description} characters). Maximum is 1024 characters."
    fi
fi

if [ -n "$warnings" ]; then
    printf '%s\n' "$warnings" | sed 's/;$/\n/' | sed 's/^/ /'
fi

echo "Skill is valid!"
exit 0