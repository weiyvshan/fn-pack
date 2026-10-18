#!/usr/bin/env bash
# init_skill.sh - Create a new skill from template (port of init_skill.py)
# Usage: bash init_skill.sh <skill-name> --path <path> [--resources scripts,references,assets] [--examples] [--interface key=value ...]
set -u

MAX_SKILL_NAME_LENGTH=64
ALLOWED_RESOURCES="scripts references assets"

# Parse args
skill_name_raw="$1"
shift || true
path=""
resources=""
examples=false
interface_raw=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --path)
            shift
            [ "$#" -gt 0 ] || { echo "option --path requires a value"; exit 1; }
            path="$1"
            ;;
        --resources)
            shift
            [ "$#" -gt 0 ] || { echo "option --resources requires a value"; exit 1; }
            resources="$1"
            ;;
        --examples)
            examples=true
            ;;
        --interface)
            shift
            [ "$#" -gt 0 ] || { echo "option --interface requires a value"; exit 1; }
            interface_raw+=("$1")
            ;;
        *)
            echo "Unknown option: $1"; exit 1
            ;;
    esac
    shift
done

[ -n "$skill_name_raw" ] || { echo "Usage: bash init_skill.sh <skill-name> --path <path> [...]" ; exit 1; }
[ -n "$path" ] || { echo "option --path is required"; exit 1; }

# Normalize skill name
skill_name="$(echo "$skill_name_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//; s/--\+/-/g')"
[ -n "$skill_name" ] || { echo "[ERROR] Skill name must include at least one letter or digit."; exit 1; }
if [ "${#skill_name}" -gt $MAX_SKILL_NAME_LENGTH ]; then
    echo "[ERROR] Skill name '$skill_name' is too long (${#skill_name} characters). Maximum is $MAX_SKILL_NAME_LENGTH characters."
    exit 1
fi
if [ "$skill_name" != "$skill_name_raw" ]; then
    echo "Note: Normalized skill name from '$skill_name_raw' to '$skill_name'."
fi

# Parse resources into the global resources_parsed. Never call through command
# substitution: the unknown-type branch exits the script, and an exit inside
# $( ) would only kill the subshell while the error text got parsed as names.
parse_resources() {
    local raw="$1"
    resources_parsed=""
    [ -n "$raw" ] || return 0
    local IFS=,
    local items=($raw)
    local IFS=' '
    local seen=""
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [ -n "$item" ] || continue
        case " $ALLOWED_RESOURCES " in
            *" $item "*) ;;
            *) echo "[ERROR] Unknown resource type(s): $item"; echo "   Allowed: scripts, references, assets"; exit 1 ;;
        esac
        case " $seen " in
            *" $item "*) ;;
            *) resources_parsed="$resources_parsed $item" ;;
        esac
        seen="$seen $item"
    done
    resources_parsed="${resources_parsed# }"
}

parse_resources "$resources"
if [ "$examples" = true ] && [ -z "$resources_parsed" ]; then
    echo "[ERROR] --examples requires --resources to be set."
    exit 1
fi

echo "Initializing skill: $skill_name"
echo "   Location: $path"
if [ -n "$resources_parsed" ]; then
    echo "   Resources: $(echo "$resources_parsed" | tr ' ' ',')"
    if [ "$examples" = true ]; then echo "   Examples: enabled"; fi
else
    echo "   Resources: none (create as needed)"
fi
echo ""

# Determine skill directory
skill_dir="$path/$skill_name"
if [ -d "$skill_dir" ]; then
    echo "[ERROR] Skill directory already exists: $skill_dir"
    exit 1
fi

# Create skill directory
mkdir -p "$skill_dir" || { echo "[ERROR] Error creating directory"; exit 1; }
echo "[OK] Created skill directory: $skill_dir"

# Title case
skill_title="$(echo "$skill_name" | sed 's/-/ /g; s/\b\([a-z]\)/\U\1/g')"

# Create SKILL.md from template. The heredoc delimiter is quoted so the
# backticked Markdown spans in the template are never treated as command
# substitutions (the PowerShell twin uses a single-quoted here-string for the
# same reason). Name and title are substituted afterwards via {placeholders}.
skill_md_path="$skill_dir/SKILL.md"
skill_md_template="$(cat <<'TMPL'
---
name: {skill_name}
description: '[TODO: Complete and informative explanation of what the skill does and when to use it. Include WHEN to use this skill - specific scenarios, file types, or tasks that trigger it. Wrap the final value in single quotes if it contains colons, brackets, or other YAML special characters. Do not use unescaped single quotes inside.]'
---

# {skill_title}

## Overview

[TODO: 1-2 sentences explaining what this skill enables]

## DSH Platform Notes

- The **description** in frontmatter is the primary triggering mechanism. Include both what the skill does AND specific contexts/scenarios that trigger it. Wrap the value in single quotes if it contains colons, brackets, or other YAML special characters.
- **Progressive disclosure**: keep SKILL.md under 500 lines. Put detailed reference material in `references/` and load it as needed rather than inlining it.
- **Scripts**: on Windows run `.ps1` with `pwsh -NoProfile -File <script>`. On Linux/macOS run `.sh` with `bash <script>`. The sandbox may block direct `.sh` execution on Windows; use Node `execSync` as a fallback.
- **Skill discovery**: skills are loaded from `~/.dsh/skills/<name>/`. The folder name must match the `name` field in frontmatter. The name must match `^[a-z0-9]+(?:-[a-z0-9]+)*$` (hyphen-case, max 64 chars).

Delete this section when done.

## Structuring This Skill

[TODO: Choose the structure that best fits this skill's purpose. Common patterns:

**1. Workflow-Based** - clear step-by-step procedures (e.g., Reading -> Creating -> Editing)
**2. Task-Based** - different operations/capabilities (e.g., Merge -> Split -> Extract)
**3. Reference/Guidelines** - standards or specifications to follow
**4. Capabilities-Based** - multiple interrelated features

Patterns can be mixed. Most skills combine patterns.

Delete this section when done.]

## [TODO: Replace with the first main section based on chosen structure]

[TODO: Add content here. See examples in existing skills:
- Code samples for technical skills
- Decision trees for complex workflows
- Concrete examples with realistic user requests
- References to scripts/templates/references as needed]

## Resources (optional)

Create only the resource directories this skill actually needs. Delete this section if no resources are required.

### scripts/
Executable code (PowerShell .ps1 on Windows, bash .sh on Linux/macOS) that can be run to perform specific operations. On Windows, run .ps1 with `pwsh -NoProfile -File <script>`. On Linux/macOS, run .sh with `bash <script>`.

### references/
Documentation and reference material intended to be loaded into context as needed.

### assets/
Files not intended to be loaded into context, but rather used within the output produced.

---

**Not every skill requires all three types of resources.**
TMPL
)"
skill_md_content="${skill_md_template//\{skill_name\}/$skill_name}"
skill_md_content="${skill_md_content//\{skill_title\}/$skill_title}"
printf '%s\n' "$skill_md_content" > "$skill_md_path"
echo "[OK] Created SKILL.md"

# Create agents/openai.yaml via generate_openai_yaml.sh
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gen_script="$script_dir/generate_openai_yaml.sh"
if [ -f "$gen_script" ]; then
    gen_args=("$skill_dir")
    for item in "${interface_raw[@]}"; do
        [ -n "$item" ] || continue
        gen_args+=("--interface" "$item")
    done
    bash "$gen_script" "${gen_args[@]}" 2>&1 || { echo "[ERROR] Error creating agents/openai.yaml"; exit 1; }
else
    echo "[WARN] generate_openai_yaml.sh not found, skipping agents/openai.yaml"
fi

# Create resource directories
if [ -n "$resources_parsed" ]; then
    for resource in $resources_parsed; do
        resource_dir="$skill_dir/$resource"
        mkdir -p "$resource_dir"
        case "$resource" in
            scripts)
                if [ "$examples" = true ]; then
                    cat > "$resource_dir/example.py" <<EX
#!/usr/bin/env python3
"""
Example helper script for $skill_name

This is a placeholder script that can be executed directly.
Replace with actual implementation or delete if not needed.
"""

def main():
    print("This is an example script for $skill_name")
    # TODO: Add actual script logic here

if __name__ == "__main__":
    main()
EX
                    echo "[OK] Created scripts/example.py"
                else
                    echo "[OK] Created scripts/"
                fi
                ;;
            references)
                if [ "$examples" = true ]; then
                    cat > "$resource_dir/api_reference.md" <<EX
# Reference Documentation for $skill_title

This is a placeholder for detailed reference documentation.
Replace with actual reference content or delete if not needed.

## When Reference Docs Are Useful

Reference docs are ideal for:
- Comprehensive API documentation
- Detailed workflow guides
- Complex multi-step processes
- Information too lengthy for main SKILL.md
EX
                    echo "[OK] Created references/api_reference.md"
                else
                    echo "[OK] Created references/"
                fi
                ;;
            assets)
                if [ "$examples" = true ]; then
                    cat > "$resource_dir/example_asset.txt" <<EX
# Example Asset File

This placeholder represents where asset files would be stored.
Replace with actual asset files (templates, images, fonts, etc.) or delete if not needed.

## Common Asset Types

- Templates: .pptx, .docx, boilerplate directories
- Images: .png, .jpg, .svg, .gif
- Fonts: .ttf, .otf, .woff, .woff2
- Data files: .csv, .json, .xml, .yaml
EX
                    echo "[OK] Created assets/example_asset.txt"
                else
                    echo "[OK] Created assets/"
                fi
                ;;
        esac
    done
fi

# Print next steps
echo ""
echo "[OK] Skill '$skill_name' initialized successfully at $skill_dir"
echo ""
echo "Next steps:"
echo "1. Edit SKILL.md to complete the TODO items and update the description"
if [ -n "$resources_parsed" ]; then
    if [ "$examples" = true ]; then
        echo "2. Customize or delete the example files in scripts/, references/, and assets/"
    else
        echo "2. Add resources to scripts/, references/, and assets/ as needed"
    fi
else
    echo "2. Create resource directories only if needed (scripts/, references/, assets/)"
fi
echo "3. Update agents/openai.yaml if the UI metadata should differ"
echo "4. Run the validator when ready to check the skill structure"
exit 0