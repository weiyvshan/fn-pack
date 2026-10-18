---
name: skill-creator
description: 'Create new skills, modify and improve existing skills. Use when the user asks to create a new skill, edit or optimize an existing skill, or set up a skill from a workflow. Supports: (1) Drafting SKILL.md with proper frontmatter and structure, (2) Generating agents/openai.yaml UI metadata, (3) Validating skill structure, (4) Iterating based on real usage.'
---

# Skill Creator

A skill for creating new skills and iteratively improving them.

## About Skills

Skills are modular, self-contained folders that extend the agent's capabilities by providing specialized knowledge, workflows, and tools. Think of them as "onboarding guides" for specific domains or tasks.

### What Skills Provide

1. **Specialized workflows** - Multi-step procedures for specific domains
2. **Tool integrations** - Instructions for working with specific file formats or APIs
3. **Domain expertise** - Project-specific knowledge, schemas, business logic
4. **Bundled resources** - Scripts, references, and assets for complex and repetitive tasks

## Core Principles

### Concise is Key

The context window is a public good. Skills share the context window with everything else the agent needs: system prompt, conversation history, other skills' metadata, and the actual user request.

**Default assumption: the agent is already very smart.** Only add context the agent doesn't already have. Challenge each piece of information: "Does the agent really need this explanation?" and "Does this paragraph justify its token cost?"

Prefer concise examples over verbose explanations.

### Set Appropriate Degrees of Freedom

Match the level of specificity to the task's fragility and variability:

- **High freedom** (text-based instructions): multiple approaches valid, decisions depend on context
- **Medium freedom** (pseudocode or scripts with parameters): a preferred pattern exists, some variation acceptable
- **Low freedom** (specific scripts, few parameters): operations are fragile, consistency is critical

### Anatomy of a Skill

Every skill consists of a required SKILL.md file and optional bundled resources:

```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name, description required)
│   └── Markdown instructions
├── agents/ (optional)
│   └── openai.yaml - UI metadata for skill lists and chips
└── Bundled Resources (optional)
    ├── scripts/          - Executable code
    ├── references/       - Documentation loaded into context as needed
    └── assets/           - Files used in output (templates, icons, fonts)
```

### Progressive Disclosure

DSH loads skills in three stages:

1. **Metadata** (name + description) - Always in context as part of the `<available_skills>` catalog. This is the primary triggering mechanism; the description must contain both what the skill does AND when to use it.
2. **SKILL.md body** - Injected as `<skill_content>` when the user invokes the skill. Keep under 500 lines. The agent can read the full file again via the `read` tool if needed.
3. **Bundled resources** (`references/`, `scripts/`, `assets/`) - Loaded on demand. The agent must `read` a reference file or script before using it; scripts are executed with `pwsh -NoProfile -File` (Windows) or `bash <script>` (Linux/macOS) after the agent knows the path.

If SKILL.md approaches 500 lines, move detailed content to `references/` and add a pointer in SKILL.md with guidance on when to read it.

## Skill Creation Process

1. **Understand** the skill with concrete examples
2. **Plan** reusable skill contents (scripts, references, assets)
3. **Initialize** the skill (run init_skill)
4. **Edit** the skill (implement resources and write SKILL.md)
5. **Validate** the skill (run quick_validate)
6. **Iterate** based on real usage

### Skill Naming

- Use lowercase letters, digits, and hyphens only
- Normalize user-provided titles to hyphen-case (e.g., "Plan Mode" → `plan-mode`)
- Prefer short, verb-led phrases that describe the action
- Name the skill folder exactly after the skill name
- Maximum 64 characters

### Step 1: Understanding the Skill

Clearly understand concrete examples of how the skill will be used. Ask:

- What functionality should the skill support?
- Can the user give examples of how it would be used?
- What would the user say that should trigger this skill?

### Step 2: Planning Reusable Contents

For each concrete example, identify what scripts, references, and assets would be helpful when executing these workflows repeatedly.

### Step 3: Initializing the Skill

Run the init_skill script to create the skill directory structure:

**Windows (PowerShell):**
```
pwsh scripts/init_skill.ps1 <skill-name> --path <output-dir> [--resources scripts,references,assets] [--examples] [--interface key=value ...]
```

**Linux/macOS (bash):**
```
bash scripts/init_skill.sh <skill-name> --path <output-dir> [--resources scripts,references,assets] [--examples] [--interface key=value ...]
```

The script creates:
- SKILL.md template with proper frontmatter and TODO placeholders
- agents/openai.yaml with UI metadata
- Optional resource directories

After initialization, the generated SKILL.md contains TODO placeholders for: frontmatter `description`, Overview, DSH Platform Notes (delete when done), Structuring This Skill (delete when done), the first main section, and Resources. Fill them in Step 4.

### Step 4: Edit the Skill

Start with the reusable resources identified in Step 2, then update SKILL.md.

**Frontmatter:** Write the `name` and `description` fields. The description is the primary triggering mechanism - include both what the skill does AND specific contexts for when to use it. All "when to use" info goes here, not in the body.

**Body:** Write instructions for using the skill and its bundled resources. Use imperative/infinitive form.

**Scripts:** When authoring PowerShell `.ps1` (in `scripts/` or `tests/`), read [references/powershell-authoring.md](references/powershell-authoring.md) for common parse and output-stream gotchas that cause real bugs.

### Step 5: Validate the Skill

**Windows (PowerShell):**
```
pwsh scripts/quick_validate.ps1 <skill-directory>
```

**Linux/macOS (bash):**
```
bash scripts/quick_validate.sh <skill-directory>
```

The validator checks YAML frontmatter format, required fields, and naming rules. If validation fails, fix the reported issues and re-run.

The validator does NOT check: description quality (sufficient trigger context), SKILL.md line count, `agents/openai.yaml` existence or format, or script permissions. Manually verify these after validation passes.

### Step 6: Iterate

After testing the skill on real tasks:
1. Notice struggles or inefficiencies
2. Identify how SKILL.md or bundled resources should be updated
3. Implement changes and test again

## openai.yaml Fields

See `references/openai_yaml.md` for the full field reference. Key fields:

- `interface.display_name`: Human-facing title (shown in UI skill lists)
- `interface.short_description`: Short UI blurb (25-64 chars)
- `interface.default_prompt`: Default prompt snippet (must mention the skill as `$skill-name`)
- `interface.icon_small` / `interface.icon_large`: Paths to icon assets
- `interface.brand_color`: Hex color for UI accents

## Writing Guidelines

- Use imperative form in instructions
- Explain **why** things are important rather than using heavy-handed MUSTs
- Keep the prompt lean - remove things that aren't pulling their weight
- Look for repeated work across test cases - if the agent keeps writing similar helper scripts, bundle that script in `scripts/`
- Avoid deeply nested references - keep references one level deep from SKILL.md
- For reference files >100 lines, include a table of contents at the top
- Do NOT create extraneous documentation files (README.md, INSTALLATION_GUIDE.md, CHANGELOG.md, etc.)
