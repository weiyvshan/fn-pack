#!/usr/bin/env bash
# generate_openai_yaml.sh - Create agents/openai.yaml for a skill folder
# Usage: bash generate_openai_yaml.sh <skill_dir> [--name <skill_name>] [--interface key=value ...]
set -u

usage() {
    echo "Usage: bash generate_openai_yaml.sh <skill_dir> [--name <skill_name>] [--interface key=value ...]"
    exit 1
}

skill_dir=""
name_override=""
interface_raw=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)
            shift
            [ "$#" -gt 0 ] || usage
            name_override="$1"
            ;;
        --interface)
            shift
            [ "$#" -gt 0 ] || usage
            interface_raw+=("$1")
            ;;
        -*)
            usage
            ;;
        *)
            if [ -z "$skill_dir" ]; then
                skill_dir="$1"
            else
                usage
            fi
            ;;
    esac
    shift
done

[ -n "$skill_dir" ] || usage
[ -d "$skill_dir" ] || { echo "Skill directory not found: $skill_dir"; exit 1; }

allowed_keys="display_name short_description icon_small icon_large brand_color default_prompt"

read_frontmatter_name() {
    local dir="$1"
    local skill_md="$dir/SKILL.md"
    [ -f "$skill_md" ] || { echo "[ERROR] SKILL.md not found in $dir"; return 1; }
    local content
    content="$(head -c 3 "$skill_md")"
    [ "$content" = "---" ] || { echo "[ERROR] Invalid SKILL.md frontmatter format."; return 1; }
    local fm
    fm="$(awk 'NR==1 { if ($0 != "---") exit 1; next } $0 == "---" { exit } { print }' "$skill_md")"
    [ -n "$fm" ] || { echo "[ERROR] Invalid SKILL.md frontmatter format."; return 1; }
    while IFS= read -r line; do
        case "$line" in
            name:*)
                local value="${line#*:}"
                value="${value#"${value%%[![:space:]]*}"}"
                value="${value%"${value##*[![:space:]]}"}"
                case "$value" in
                    \"*\") value="${value#\"}"; value="${value%\"}" ;;
                    \'*\') value="${value#\'}"; value="${value%\'}" ;;
                esac
                [ -n "$value" ] && { echo "$value"; return 0; }
                ;;
        esac
    done <<EOF
$fm
EOF
    echo "[ERROR] Frontmatter 'name' is missing or invalid."
    return 1
}

format_display_name() {
    local skill_name="$1"
    local acronyms="GH MCP API CI CLI LLM PDF PR UI URL SQL"
    local brands="openai:OpenAI openapi:OpenAPI github:GitHub pagerduty:PagerDuty datadog:DataDog sqlite:SQLite fastapi:FastAPI"
    local small_words="and or to up with"
    local words=()
    local IFS='-'
    read -ra words <<< "$skill_name"
    local IFS=' '
    local formatted=""
    local idx=0
    for word in "${words[@]}"; do
        [ -n "$word" ] || continue
        local lower upper
        lower="$(echo "$word" | tr '[:upper:]' '[:lower:]')"
        upper="$(echo "$word" | tr '[:lower:]' '[:upper:]')"
        if echo "$acronyms" | grep -qw "$upper"; then
            formatted="$formatted $upper"
        elif echo "$brands" | grep -q "^$lower:"; then
            local brand_val
            brand_val="$(echo "$brands" | grep "^$lower:" | cut -d: -f2)"
            formatted="$formatted $brand_val"
        elif [ "$idx" -gt 0 ] && echo " $small_words " | grep -qw "$lower"; then
            formatted="$formatted $lower"
        else
            formatted="$formatted $(echo "$word" | cut -c1 | tr '[:lower:]' '[:upper:]')$(echo "$word" | cut -c2-)"
        fi
        idx=$((idx + 1))
    done
    echo "${formatted# }"
}

generate_short_description() {
    local display_name="$1"
    local d="Help with $display_name tasks"
    if [ "${#d}" -lt 25 ]; then d="Help with $display_name tasks and workflows"; fi
    if [ "${#d}" -lt 25 ]; then d="Help with $display_name tasks with guidance"; fi
    if [ "${#d}" -gt 64 ]; then d="Help with $display_name"; fi
    if [ "${#d}" -gt 64 ]; then d="$display_name helper"; fi
    if [ "${#d}" -gt 64 ]; then d="$display_name tools"; fi
    if [ "${#d}" -gt 64 ]; then
        local suffix=" helper"
        local max_len=$((64 - ${#suffix}))
        local trimmed="${display_name:0:$max_len}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        d="$trimmed$suffix"
    fi
    if [ "${#d}" -gt 64 ]; then d="${d:0:64}"; d="${d%"${d##*[![:space:]]}"}"; fi
    if [ "${#d}" -lt 25 ]; then
        d="$d workflows"
        if [ "${#d}" -gt 64 ]; then d="${d:0:64}"; d="${d%"${d##*[![:space:]]}"}"; fi
    fi
    echo "$d"
}

yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    echo "\"$value\""
}

skill_name="${name_override:-}"
if [ -z "$skill_name" ]; then
    skill_name="$(read_frontmatter_name "$skill_dir")" || exit 1
fi

overrides_display_name=""
overrides_short_desc=""
# Optional overrides stay in parallel arrays: a "key=value;" string could not
# survive values containing ';' (ifs splitting) — the PowerShell twin uses a
# hashtable for the same reason.
overrides_other_keys=()
overrides_other_vals=()

for item in "${interface_raw[@]}"; do
    [ -n "$item" ] || continue
    case "$item" in
        *=*) ;;
        *) echo "Invalid interface override '$item'. Use key=value."; exit 1 ;;
    esac
    key="${item%%=*}"
    val="${item#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    [ -n "$key" ] || { echo "Invalid interface override '$item'. Key is empty."; exit 1; }
    case " $allowed_keys " in
        *" $key "*) ;;
        *) echo "Unknown interface field '$key'. Allowed: display_name, short_description, icon_small, icon_large, brand_color, default_prompt"; exit 1 ;;
    esac
    case "$key" in
        display_name) overrides_display_name="$val" ;;
        short_description) overrides_short_desc="$val" ;;
        *)
            overrides_other_keys+=("$key")
            overrides_other_vals+=("$val")
            ;;
    esac
done

display_name="${overrides_display_name:-$(format_display_name "$skill_name")}"
short_desc="${overrides_short_desc:-$(generate_short_description "$display_name")}"

if [ "${#short_desc}" -lt 25 ] || [ "${#short_desc}" -gt 64 ]; then
    echo "[ERROR] short_description must be 25-64 characters (got ${#short_desc})."
    exit 1
fi

agents_dir="$skill_dir/agents"
mkdir -p "$agents_dir"
out_path="$agents_dir/openai.yaml"

{
    echo "interface:"
    echo "  display_name: $(yaml_quote "$display_name")"
    echo "  short_description: $(yaml_quote "$short_desc")"
    if [ "${#overrides_other_keys[@]}" -gt 0 ]; then
        for idx in "${!overrides_other_keys[@]}"; do
            echo "  ${overrides_other_keys[$idx]}: $(yaml_quote "${overrides_other_vals[$idx]}")"
        done
    fi
} > "$out_path"

echo "[OK] Created agents/openai.yaml"
exit 0