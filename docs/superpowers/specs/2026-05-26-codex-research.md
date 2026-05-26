# Codex CLI Research Findings (for Task 6/7/8)

> Researched: 2026-05-26. Codex not installed locally; findings are from official docs,
> raw GitHub source (openai/codex), and https://developers.openai.com/codex/*.

---

## Q1: Codex installed?

**NOT installed** on this machine.

```
$ which codex
codex not found
$ codex --version
command not found: codex
```

Codex CLI installs via npm: `npm i -g @openai/codex` (TypeScript/Rust hybrid).
Live verification of Q4 (stdin-wait) and Q5 (smoke test) must shift to **Task 9**.

---

## Q2: Flag analogs to Claude Code minimal-startup stack

| Claude Code flag | Purpose | Codex equivalent | Notes |
|---|---|---|---|
| `--system-prompt` / `-p` | Replace default system prompt | **`-c instructions="..."`** | Set via inline config override. TOML key is `instructions`. Alternatively `developer_instructions` for a developer-role message. No dedicated `--system-prompt` flag exists. |
| `--setting-sources ""` | Skip user/proj/local settings | **`--ignore-user-config`** | Skips `$CODEX_HOME/config.toml`. Partial analog — skips user config but not project-level `.codex-plugin` / `.agents/` discovery. |
| `--strict-mcp-config` | Ignore default MCP config | No direct analog | MCP servers are configured via `mcp_servers` in config.toml. `--ignore-user-config` suppresses user-level MCP config. No separate strict-MCP flag. |
| `--mcp-config '{...}'` | Inject empty MCP config | **`-c mcp_servers={}`** (untested) | The `-c key=value` flag applies inline TOML overrides. Passing an empty `mcp_servers` table should suppress MCP, but this is unverified without a live binary. |
| `--no-session-persistence` | Don't write transcript | **`--ephemeral`** | "Run without persisting session rollout files to disk." Direct analog. |
| `--tools ""` | No tool defs (saves ~11k tokens) | **No equivalent found** | No `--no-tools` or `--tools ""` flag exists. Tools config lives under `[tools]` in TOML (only `web_search` sub-key documented). There is no CLI switch to emit zero tool definitions. This is the largest gap. |
| `--effort low` | Suppress thinking | **`-c model_reasoning_effort=low`** | Config key `model_reasoning_effort` exists (also `plan_mode_reasoning_effort`). Settable via `-c`. |
| `--model` | Choose model | **`--model` / `-m`** | Direct analog. e.g. `--model gpt-4o-mini`. |
| `--fallback-model` | Fallback if primary overloaded | **No equivalent found** | Not documented. Likely OpenAI API handles fallback server-side. |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | No background HTTP | **No equivalent found** | Not documented. Codex is a newer tool; telemetry controls may exist but are undocumented. |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` | No /memory/ auto-load | **No equivalent found** | Codex has a `memories/` system but no documented env var to disable it. |
| `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` | No CLAUDE.md auto-discovery | **`--ignore-rules`** (partial) | `--ignore-rules` skips execpolicy `.rules` files. Skills/SKILL.md are still auto-discovered. No direct analog to disabling instruction-file auto-discovery. |
| `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1` | No git-status injection | **`--skip-git-repo-check`** (partial) | Skips the git-repo requirement check; may suppress git-context injection, but this is inferred, not documented. |

### Codex-specific flags worth using in the hook

| Flag | Purpose |
|---|---|
| `--ephemeral` | Don't persist session files (essential for a hook) |
| `--ignore-user-config` | Skip user's `config.toml` (speeds startup, avoids stray MCP) |
| `--ignore-rules` | Skip execpolicy `.rules` files |
| `--skip-git-repo-check` | Allow running outside a Git repo |
| `--sandbox read-only` | Prevent any file writes / shell commands (safe for coach task) |
| `--json` | Machine-readable newline-delimited JSON events (scriptable) |
| `-o <path>` / `--output-last-message` | Write final assistant message to a file (great for hooks) |
| `-c model_reasoning_effort=low` | Suppress thinking tokens (latency win) |
| `--model gpt-4o-mini` | Cheapest/fastest model for the coach task |

### Configuration override syntax

```bash
# -c accepts repeatable TOML key=value pairs
codex exec -c instructions="$SYSTEM_PROMPT" \
           -c model_reasoning_effort=low \
           --model gpt-4o-mini \
           --ephemeral \
           --ignore-user-config \
           --ignore-rules \
           --sandbox read-only \
           "$USER_PROMPT"
```

---

## Q3: System prompt delivery

**No dedicated `--system-prompt` / `--developer-message` / `--instructions` CLI flag exists.**

System instructions must be injected via the inline config override:

```bash
codex exec -c instructions="SYSTEM INSTRUCTIONS HERE" ...
```

The TOML config key is `instructions` (system role) or `developer_instructions` (developer role).

**For the portable v0.1.0 shape**, Task 6 should also keep the fallback of prepending
`SYSTEM_INSTR` into the user message string, in case `-c instructions=...` causes
quoting issues with complex multi-line prompts in shell. Both methods should be tested
in Task 9.

Alternative: write a temp config file with `instructions = "..."` and reference it via
`--profile` (profiles layer onto the base config), but `-c` inline is simpler.

---

## Q4: Stdin-wait penalty

**Cannot measure — Codex is not installed.** Deferred to Task 9.

What the docs say about stdin:
- `codex exec "instruction" < data.txt` — piped input becomes additional context
- `codex exec -` — reads the entire prompt from stdin (replaces the prompt argument)
- When a PROMPT argument is provided alongside piped stdin, the piped data is treated as context, not the prompt

**Recommendation:** Use `< /dev/null` in the hook (same as Claude Code) to be safe, since
any stdin-wait behavior would add latency. Confirm in Task 9.

---

## Q5: gpt-5-mini / gpt-4o-mini smoke test

**Cannot run — Codex is not installed.** Deferred to Task 9.

From documentation:
- Model name used in docs examples: `gpt-5.4`, `gpt-5.3-Codex`
- The flag is `--model` / `-m` with a free-form model string
- `CODEX_API_KEY` or `OPENAI_API_KEY` must be set in the environment
- `~/.codex/auth.json` is used for saved authentication

For Task 9, try in order:
1. `codex exec --model gpt-4o-mini ...`
2. `codex exec --model gpt-4o ...`
3. `codex exec --model gpt-5.4 ...` (if account has access)

The redpen hook should default to `gpt-4o-mini` (analogous to Claude Haiku).

---

## Q6: Plugin command registration

### Skills vs. commands/*.md

Codex uses **SKILL.md files** (not `commands/*.md`) as the plugin command format.

- Each skill lives in its own subdirectory with a `SKILL.md` file:
  ```
  plugins/redpen-codex/skills/setup/SKILL.md
  ```
- The `SKILL.md` uses YAML frontmatter with `name` and `description` fields
- Skills are **auto-discovered** from `.agents/skills` directories at:
  - Repository-level: `.agents/skills/` in current and parent directories up to repo root
  - User-level: `$HOME/.agents/skills/`
  - Admin-level: `/etc/codex/skills/`
  - Plugin-installed: registered via `manifest.paths.skills` in `.codex-plugin/plugin.json`
- **No symlinks to `~/.codex/prompts/` needed** — the old custom-prompts system (`~/.codex/prompts/*.md`) is **deprecated** in favor of skills

### Auto-registration behavior

- When a plugin is installed, Codex reads the plugin manifest (`.codex-plugin/plugin.json`)
- The manifest's `paths.skills` field points to the skills directory
- Skills in that directory are **auto-loaded and registered** — no manual symlink step
- Codex "detects skill changes automatically" without restart for the interactive TUI

### Invocation syntax

- **Explicit:** Type `$skill-name` in a prompt or use `/skills` command to browse
- **Implicit:** Codex autonomously selects the skill matching the task
- **NO namespaced syntax like `/redpen-codex:setup`** — Codex skills use `$skill-name` (dollar prefix), not slash-colon namespace
- The setup skill would be invoked as `$setup` or `$redpen-setup` (depending on name field in SKILL.md)

### The `commands/*.md` format is Claude Code only

The existing `plugins/redpen/commands/setup.md` format **does NOT apply to Codex**. For Codex, the equivalent is:

```
plugins/redpen-codex/skills/setup/SKILL.md   ← Codex format
plugins/redpen/commands/setup.md              ← Claude Code format (existing)
```

The SKILL.md frontmatter for setup would look like:
```yaml
---
name: redpen-setup
description: Configure the redpen-codex plugin (language + model). Invoke when the user says "set up redpen" or "configure language coaching".
allowed-tools: Read, Write
---
```

---

## Q7: Marketplace format

### Key finding: `.claude-plugin/marketplace.json` IS recognized by Codex

From reading `codex-rs/core-plugins/src/marketplace.rs` source:

> "Manifests must be located at either: `.agents/plugins/marketplace.json` OR `.claude-plugin/marketplace.json`"

This means Codex has **explicit interop** with the Claude Code marketplace location — both formats are supported. The existing `redpen/.claude-plugin/marketplace.json` is already at the right path.

### However, the Codex marketplace JSON schema differs from Claude Code's

**Claude Code** `.claude-plugin/marketplace.json` (current):
```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "redpen",
  "plugins": [
    {
      "name": "redpen",
      "source": "./plugins/redpen",
      "category": "productivity"
    }
  ]
}
```

**Codex** marketplace.json schema:
```json
{
  "name": "marketplace-name",
  "plugins": [
    {
      "name": "plugin-name",
      "source": { "source": "local", "path": "./plugins/redpen-codex" },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "productivity"
    }
  ]
}
```

Key differences:
- `source` must be an object `{ "source": "local", "path": "..." }` (or `"url"` / `"git-subdir"` for remote)
- `policy` object with `installation` and `authentication` fields is required/expected
- No `$schema` key (or a different one)
- The plugin itself needs a `.codex-plugin/plugin.json` manifest (not `.claude-plugin/marketplace.json`)

### Install command syntax

```bash
# Add a marketplace (local or GitHub repo):
codex plugin marketplace add ./path/to/repo
codex plugin marketplace add owner/repo          # GitHub shorthand

# Plugin management after marketplace is added:
codex plugin add <plugin-name>
codex plugin list
codex plugin remove <plugin-name>
```

No single `codex plugin install <name>@<marketplace>` syntax found — the flow is:
1. `codex plugin marketplace add <source>` → registers the marketplace
2. Plugin becomes available in `/plugins` browser or `codex plugin add`

### Recommendation for Task 8

- Add a `.agents/plugins/marketplace.json` as the **Codex-native path** (preferred)
- Keep `.claude-plugin/marketplace.json` for Claude Code (separate entry pointing to Claude Code plugin)
- Or: update `.claude-plugin/marketplace.json` to be a dual-format file (Claude Code ignores unknown keys, Codex reads the `policy` field)
- Each plugin variant (redpen vs redpen-codex) needs its own `.codex-plugin/plugin.json`

---

## Recommended Codex flag stack for the hook

Based on research (needs Task 9 live verification):

```bash
codex exec \
  --model "${CODEX_MODEL:-gpt-4o-mini}" \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --skip-git-repo-check \
  --sandbox read-only \
  -c "model_reasoning_effort=low" \
  -c "instructions=${SYSTEM_INSTR}" \
  -o /tmp/redpen-codex-output.txt \
  "${USER_MSG}" \
  < /dev/null
```

Or without `instructions` via `-c` if quoting proves fragile, prepend to prompt instead:

```bash
FULL_PROMPT="${SYSTEM_INSTR}

---

${USER_MSG}"

codex exec \
  --model "${CODEX_MODEL:-gpt-4o-mini}" \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --skip-git-repo-check \
  --sandbox read-only \
  -c "model_reasoning_effort=low" \
  -o /tmp/redpen-codex-output.txt \
  "${FULL_PROMPT}" \
  < /dev/null
```

**Note:** `--json` mode is useful for scripting but requires parsing newline-delimited JSON to extract the final message. Using `-o <path>` is simpler for the hook.

---

## Open questions for Task 6/7/8 to resolve at implementation time

1. **`-c instructions="..."` quoting**: Does the shell handle multi-line system prompt strings correctly when passed via `-c`? If not, write to a temp `config.toml` and use `--profile` instead.

2. **No `--no-tools` equivalent**: Codex has no flag to suppress tool definitions from the context window. This means the coach prompt payload will be larger than the Claude Code equivalent. Measure token overhead in Task 9 and decide if it matters.

3. **`--ignore-user-config` scope**: Does this flag suppress ALL config sources (project `.agents/`, env vars) or only `$CODEX_HOME/config.toml`? From source, it appears to skip only the user config file. Skills discovery from `.agents/skills` in the project tree may still fire — this could be harmless or cause slight latency. Test in Task 9.

4. **Stdin behavior with `/dev/null`**: Unverified whether `< /dev/null` causes a hang, no-op, or error in `codex exec`. Task 9 should test both with and without.

5. **Model availability**: Confirm which models are available on the target account (`gpt-4o-mini`, `gpt-4o`, `gpt-5.4`). The config file at `~/.codex/redpen.config` should store the Codex model separately from the Claude model (they have different name formats).

6. **Plugin manifest**: Task 4 must create `.codex-plugin/plugin.json` for the redpen-codex plugin. The manifest must point `paths.skills` to the skills directory and optionally set `paths.hooks` for the post-prompt hook.

7. **Skills invocation in Codex TUI only**: Skills (`$redpen-setup`) only work in the **interactive TUI**. The `codex exec` non-interactive path does NOT use skills. The setup command will be a TUI-only feature, which is fine.

8. **Hooks in `codex exec`**: The pre/post-prompt hook that triggers the coach is a Codex plugin hook (not a skills invocation). Confirm whether `hooks/hooks.json` is respected during `codex exec` or only in TUI mode. From the build-plugins doc: "Installing a plugin doesn't automatically trust its hooks — users must review before execution." This may require Task 9 user-facing approval step on first run.

9. **Separate config file path**: The Claude Code plugin stores config at `~/.claude/redpen.config`. The Codex port should use a separate path (e.g., `~/.codex/redpen.config`) to avoid collision when both plugins are installed simultaneously.

10. **Output parsing from `codex exec`**: The hook reads the coach output. With `-o /tmp/...` the final message goes to a file cleanly. Without `-o`, output goes to stdout mixed with potential progress messages. Use `-o` and optionally `--json` for clean separation.
