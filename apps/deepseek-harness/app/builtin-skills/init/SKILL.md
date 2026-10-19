---
name: init
description: Create or update a repository's AGENTS.md, the contributor guide that DSH auto-loads at session start. Use when the user says "init", "/init", "initialize AGENTS.md", or asks to create/refresh repo instructions for agents.
---

# Init: Generate / Update AGENTS.md

Ported from Codex's `/init` (codex-rs/tui/assets/prompt_for_init_command.md), with an added update flow: Codex refuses to touch an existing AGENTS.md; this skill incrementally refreshes it instead.

## Mode Selection

1. If `<repo>/AGENTS.md` does NOT exist → **create mode**.
2. If it exists → **update mode**. Never discard user-authored content; refresh only stale facts (commands, paths, tool versions, structure).

## Step 1 — Passive Recon (no writes yet)

Collect evidence before writing a single line. Never guess a command that you have not seen in a config file:

- Top-level layout: `ls` the root; note src/test/docs/asset locations.
- Manifests & toolchain: `package.json` (scripts, packageManager), `Makefile`/`justfile`, `pyproject.toml`/`setup.py`, `Cargo.toml`, `go.mod`, `composer.json`, lockfiles, `.nvmrc`/`.tool-versions`.
- Lint/format config: eslint/prettier/ruff/black/gofmt/clippy/stylelint configs.
- CI: `.github/workflows/*`, `.gitlab-ci.yml` — these reveal the canonical build/test pipeline.
- Commit conventions: `git log --oneline -30` (conventional commits? plain?).
- Existing agent docs: nested `AGENTS.md`, `CLAUDE.md`, `CONTEXT.md` — link, don't duplicate.
- Monorepo: if multiple distinct subprojects exist, ask whether to also generate per-directory AGENTS.md files (agents.md spec supports nesting; the root file then stays thin).

## Step 2 — Write the Document (create mode)

Follow the Codex outline, adapted to evidence found:

- Title the document `# Repository Guidelines` (keep the English heading even in Chinese-language repos; body language follows the repo's dominant language).
- Use Markdown headings for structure.
- 200–400 words is optimal; keep it concise — AGENTS.md is injected into EVERY session's context, bloat has a token cost.
- Short, direct, repo-specific statements with concrete examples (commands, paths, naming patterns).
- Every command listed must come from Step 1 evidence (a script in package.json, a Makefile target, a CI step). If the standard test command cannot be found, write that explicitly rather than inventing one.

Recommended sections (add/omit as evidence dictates):

1. **Project Structure & Module Organization** — where source, tests, and assets live.
2. **Build, Test, and Development Commands** — key commands and what each does.
3. **Coding Style & Naming Conventions** — indentation, language style, naming patterns, formatters/linters used.
4. **Testing Guidelines** — frameworks, coverage requirements, test naming, how to run.
5. **Commit & Pull Request Guidelines** — conventions observed in git history; PR requirements.
6. Optional: Security & Configuration Tips, Architecture Overview, Agent-Specific Instructions.

## Step 3 — Update Mode

- Read the existing AGENTS.md fully first.
- Classify each section: still-accurate / stale / missing-topic.
- Verify every factual claim (commands, paths) against current configs the same way as Step 1; fix only what's wrong or outdated.
- Preserve user-written prose, opinions, and rules verbatim unless factually contradicted.
- Add missing recommended sections only if evidence supports them.
- Report a summary of changes to the user; do not silently rewrite.

## Step 4 — Report

Tell the user:

- Created or updated: `<abs path to AGENTS.md>`
- Word count (target 200–400).
- Which sections were refreshed (update mode).
- Reminder: DSH loads workspace-level AGENTS.md at session start — a new/updated file takes effect from the NEXT session (or context reload), not the current turn.
- Suggest committing the file (it is meant to be checked into git).

## Hard Rules

- No secrets, tokens, credentials, or private paths in the generated file.
- No fabricated commands. Absence of evidence → state the gap or omit the section.
- Don't touch `~/.dsh/AGENTS.md` (user-level); this skill operates on the target repository only.
- Keep it under 400 words in create mode; in update mode, prune grown files back toward that budget.
