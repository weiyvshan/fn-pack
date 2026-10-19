#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INIT_SCRIPT="${ROOT}/app/builtin-skills/skill-creator/scripts/init_skill.sh"
VALIDATE_SCRIPT="${ROOT}/app/builtin-skills/skill-creator/scripts/quick_validate.sh"
GENERATE_SCRIPT="${ROOT}/app/builtin-skills/skill-creator/scripts/generate_openai_yaml.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-skill-creator.XXXXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

invalid_root="${temporary_root}/invalid"
mkdir -p "$invalid_root"
set +e
invalid_output=$(bash "$INIT_SCRIPT" invalid-resource --path "$invalid_root" --resources scripts,foo 2>&1)
invalid_status=$?
set -e
[ "$invalid_status" -ne 0 ] || fail 'invalid resource type unexpectedly succeeded'
printf '%s\n' "$invalid_output" | grep -Fq '[ERROR] Unknown resource type(s): foo' ||
  fail 'invalid resource error is not actionable'
[ -z "$(find "$invalid_root" -mindepth 1 -print -quit)" ] ||
  fail 'invalid resource type created files or directories'

sentinel="${temporary_root}/command-substitution-ran"
fake_bin="${temporary_root}/bin"
valid_root="${temporary_root}/valid"
mkdir -p "$fake_bin" "$valid_root"
for command_name in .ps1 .sh; do
  command_path="${fake_bin}/${command_name}"
  printf '#!/bin/sh\nprintf %%s\\n executed >>"%s"\n' "$sentinel" >"$command_path"
  chmod 0755 "$command_path"
done

PATH="${fake_bin}:${PATH}" bash "$INIT_SCRIPT" literal-template --path "$valid_root" >/dev/null
skill_dir="${valid_root}/literal-template"
[ ! -e "$sentinel" ] || fail 'SKILL.md template executed Markdown command substitutions'
grep -Fq 'Put detailed reference material in `references/`' "$skill_dir/SKILL.md" ||
  fail 'generated SKILL.md did not preserve reference backticks literally'
grep -Fq 'on Windows run `.ps1` with `pwsh -NoProfile -File <script>`' "$skill_dir/SKILL.md" ||
  fail 'generated SKILL.md did not preserve script examples literally'
grep -Fq '# Literal Template' "$skill_dir/SKILL.md" ||
  fail 'generated SKILL.md did not inject the validated title'
bash "$VALIDATE_SCRIPT" "$skill_dir" >/dev/null

spaced_key_skill="${temporary_root}/spaced-key-skill"
mkdir -p "$spaced_key_skill"
cat >"${spaced_key_skill}/SKILL.md" <<'EOF'
---
name : spaced-key-skill
description : Validate frontmatter keys that include whitespace before the colon.
---

# Spaced Key Skill
EOF
bash "$VALIDATE_SCRIPT" "$spaced_key_skill" >/dev/null ||
  fail 'quick validator rejected frontmatter keys with whitespace before the colon'

interface_value='Use C:\work\skills; keep; every; segment'
bash "$GENERATE_SCRIPT" "$skill_dir" --interface "default_prompt=$interface_value" >/dev/null
grep -Fq '  default_prompt: "Use C:\\work\\skills; keep; every; segment"' "$skill_dir/agents/openai.yaml" ||
  fail 'openai.yaml generation did not preserve backslashes and semicolons'

printf '%s\n' 'skill-creator tests passed'
