# redpen-codex Design

**Date:** 2026-05-26
**Status:** Draft — pending user review
**Goal:** Ship a Codex CLI version of the redpen plugin that mirrors the Claude Code version's UX (inline `[NN] <rewrite>` shown via `systemMessage`, never added to model context), sharing as much code as possible with the existing plugin.

## Background

`redpen` is a Claude Code plugin that grades every prompt the user types and shows a rewritten version inline. The Claude Code version is shipped and stable; see `plugins/redpen/`. OpenAI's Codex CLI (`@openai/codex`) recently added a hook system that is API-compatible with Claude Code's at the surface level — same `UserPromptSubmit` event name, same JSON stdin shape, same `systemMessage` output field semantics, same `hooks/hooks.json` plugin layout. This makes a Codex port mostly a matter of swapping the headless LLM call and the manifest directory name, plus stripping a few Claude-specific optimizations.

## Non-goals

- No support for Codex IDE extension, Codex app, or `codex.com` web UI — CLI only.
- No `SessionStart` prewarm hook on the Codex side. (The Claude Code prewarm exists to amortize Node bundle parse cost on `claude -p` cold starts; we don't know yet whether `codex exec` has the same problem, and the user explicitly excluded prewarm from scope.)
- No shared `~/.redpen.config`. Each CLI gets its own config file because the `MODEL` field's accepted values are vendor-specific and would collide.

## Architecture

### Repository layout

```
redpen/
├── README.md                                    ← document both plugins
├── LICENSE
├── .claude-plugin/marketplace.json              ← keep existing entry; add Codex entry if format supports it
├── plugins/
│   ├── redpen/                                  ← existing Claude Code plugin (unchanged this PR)
│   │   └── ...
│   ├── redpen-codex/                            ← NEW
│   │   ├── .codex-plugin/plugin.json
│   │   ├── hooks/
│   │   │   ├── hooks.json
│   │   │   └── grammar_check.sh
│   │   └── commands/setup.md                    ← /redpen-codex:setup
│   └── shared/                                  ← NEW
│       ├── coach_prompts.sh                     ← extracted SYSTEM_INSTR strings (4 languages)
│       └── render_diff.py                       ← extracted Python diff/ANSI rendering
```

Both plugins `source` `plugins/shared/coach_prompts.sh` and pipe through `plugins/shared/render_diff.py`. The existing Claude Code `grammar_check.sh` is refactored to delegate to these in the same PR (extracting in place — the bodies don't change, just where they live).

### Codex hook registration

`plugins/redpen-codex/.codex-plugin/plugin.json`:
```json
{
  "name": "redpen-codex",
  "description": "Scores and rewrites every user prompt in your chosen target language. Codex CLI port of redpen.",
  "version": "0.1.0",
  "author": { "name": "roger.kwan" },
  "keywords": ["language", "learning", "english", "chinese", "spanish", "japanese", "hooks", "codex"]
}
```

`plugins/redpen-codex/hooks/hooks.json`:
```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${PLUGIN_ROOT}/hooks/grammar_check.sh\"",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

Note: `${PLUGIN_ROOT}` is the Codex env var name. Codex documents `CLAUDE_PLUGIN_ROOT` as a compatibility alias, but we use the native name in new code.

### Codex `grammar_check.sh` differences from Claude Code version

| Concern | Claude Code | Codex |
|---|---|---|
| Config file path | `~/.claude/redpen.config` | `~/.codex/redpen.config` |
| Recursion guard env | `REDPEN_ACTIVE=1` | same |
| Log file | `~/.claude/redpen.log` | `~/.codex/redpen.log` |
| Default model | `haiku` (alias) | `gpt-5-mini` (see Model decision below) |
| LLM invocation | `claude -p ...` with minimal-startup flag stack | `codex exec ...` with equivalent flag stack (see below) |
| Model-specific branches | Haiku addendum (force `ANALYSIS:` line, disable thinking, 20 few-shot examples) and Opus slim prompt | None initially — all OpenAI models go through the base prompt. Specializations added later only if a bench shows a clear win. |
| Harness envelope skip patterns | `<task-notification>` … `<user-prompt-submit-hook>` | Same list (Codex inherits the same envelope conventions per the compat shim) |
| Slash / shell passthrough skip | Yes | Same |
| MAX_PROMPT_CHARS | 2000 | Same |
| systemMessage JSON output | Yes | Same (verified — Codex's `systemMessage` is documented as "Surfaced as a warning in the UI or event stream", which matches the redpen UX) |

### `codex exec` flag stack — what to figure out empirically

The Claude Code version's flag stack (`--setting-sources ""`, `--strict-mcp-config`, `--mcp-config '{...}'`, `--no-session-persistence`, `--tools ""`, `--effort low`, `</dev/null`) cut median latency from ~7.5s to ~1.2s. We don't yet know:

1. Which `codex exec` flags have analogous effects.
2. Whether `codex exec` has a stdin-wait penalty like `claude -p`'s 3-second hang.
3. Whether there's a `--no-tools` equivalent that drops tool-spec input bloat.
4. Whether `codex exec` writes a transcript by default and how to disable it.

**Plan:** Initial implementation uses the minimum viable flag set:
```bash
codex exec --model "$MODEL" --skip-git-repo-check "$USER_MSG" </dev/null
```
Then run a bench similar to `bench/` in the existing repo to find the latency floor, and add flags one by one. Document the chosen flag stack in script comments alongside its measured impact, just like the Claude Code version does.

### Shared files

**`plugins/shared/coach_prompts.sh`** — sourceable bash file that sets `SYSTEM_INSTR` based on `$LANGUAGE`. Exposes the four language-specific multi-line strings verbatim from the current `grammar_check.sh`. No logic changes.

**`plugins/shared/render_diff.py`** — Python script invoked via env vars (`REWRITTEN`, `ORIGINAL_PROMPT`, `LT_LANGUAGE`) and prints the final `{"systemMessage": "..."}` JSON to stdout. This is lifted verbatim from the heredoc in current `grammar_check.sh`. Both plugins call it the same way:
```bash
OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ORIGINAL_PROMPT="$PROMPT" LT_LANGUAGE="$LANGUAGE" \
    /usr/bin/python3 "$SHARED_DIR/render_diff.py")"
```

Each plugin computes `SHARED_DIR` relative to `$PLUGIN_ROOT` (or `$CLAUDE_PLUGIN_ROOT`): `"$PLUGIN_ROOT/../shared"`.

### `/redpen-codex:setup` command

Codex supports plugin-bundled custom commands via the `commands/` directory (same convention as Claude Code). The command file `plugins/redpen-codex/commands/setup.md` is a near-copy of the Claude Code version with three differences:

1. Reads/writes `~/.codex/redpen.config` instead of `~/.claude/redpen.config`.
2. The Model question lists OpenAI model families instead of Claude families:
   - `gpt-5-mini (Recommended)` — fastest and cheapest OpenAI model suitable for this task
   - `gpt-5` — balanced
   - `gpt-4o-mini` — legacy fallback
   - Other — accept any model id `codex exec --model` accepts
3. Step 5's confirmation line uses OpenAI model family names.

If Codex's custom-command discovery turns out NOT to load plugin-bundled commands at install time (the docs say custom prompts live in `~/.codex/prompts/` — unclear whether plugin `commands/` get auto-registered), the fallback is to ship `setup.md` as-is and have the README instruct users to symlink it into `~/.codex/prompts/redpen-codex-setup.md`. This is a contingency, not the default plan — initial implementation tries the plugin-bundled path first.

### First-run nudge

The Claude Code version emits a `UserPromptSubmit` `additionalContext` block on every prompt when `~/.claude/redpen.config` is missing, telling Claude to invoke `/redpen:setup` via the Skill tool. The Codex equivalent uses the same `additionalContext` mechanism (Codex shares this JSON schema) but the wording switches from "invoke via the Skill tool" to "invoke the `/redpen-codex:setup` slash command" — Codex doesn't have a Skill tool. The expectation is that Codex will see the directive and run the slash command on the same turn.

### Model decision

**Recommended default:** `gpt-5-mini`.

Rationale: It plays the same role for Codex that Haiku plays for Claude Code — cheapest, fastest, well-suited to short structured-output tasks like score + rewrite. If a bench shows latency or quality issues, fall back to `gpt-4o-mini` as the documented alternative.

Open: Codex CLI typically auto-detects a default model from `~/.codex/config.toml`. Should `MODEL=` (empty) mean "follow Codex's configured default" the way the Claude Code version's empty `MODEL=` follows `/model`? Yes — this is the consistent design and works as long as `codex exec` honors the user's config when `--model` is omitted.

## Data flow (Codex version)

```
You submit a prompt in Codex CLI
         │
         ▼
  UserPromptSubmit hook fires (plugins/redpen-codex/hooks/grammar_check.sh)
         │
         ▼
  Source plugins/shared/coach_prompts.sh → SYSTEM_INSTR set per $LANGUAGE
         │
         ▼
  Strip /cmd token, skip empty / shell / pure-slash / harness-envelope prompts
         │
         ▼
  Spawn `codex exec` from $TMPDIR with the minimal-startup flag stack
  + REDPEN_ACTIVE=1 (recursion guard)
         │
         ▼
  Receive "[NN] <rewrite>\n──── … ────\n<colloquial>"
         │
         ▼
  Pipe through plugins/shared/render_diff.py
         │
         ▼
  Emit JSON {"systemMessage": "\n<colored diff>"}
         │
         ▼
  Codex displays it inline; model never sees the feedback
```

## Error handling

All failures degrade silently to "skip coaching this turn" (exit 0 without emitting JSON). Specifically:
- `codex` binary not on PATH → log, exit 0
- `codex exec` returns empty / errors → log, exit 0
- Output doesn't match `[NN] ...` format → treated as score 0 (existing behavior in `render_diff.py`)
- Recursion guard tripped → exit 0 fast

The hook MUST NOT block the user's prompt from reaching Codex under any circumstance, including hook timeout. The `hooks.json` timeout is 60s as a backstop; the hook itself never blocks longer than the headless call.

## Testing

No automated tests for either plugin today. Manual verification plan for the Codex version, in order:

1. Install Codex CLI, run `codex` with the plugin enabled.
2. Submit an English prompt with a typo → see colored `[NN] <rewrite>` line.
3. Submit a Chinese prompt → see `[0] <english rewrite>` (foreign-character rule).
4. Submit `/help` → no rewrite (pure slash skip).
5. Submit `!ls` → no rewrite (shell passthrough skip).
6. Submit a 3000-char paste → no rewrite (length skip).
7. Delete `~/.codex/redpen.config`, restart → first prompt triggers `/redpen-codex:setup`.
8. Run `/redpen-codex:setup`, switch language to `chinese`, verify next prompt is coached in Chinese.

If these all pass, ship 0.1.0.

## Things explicitly deferred

- **Prewarm.** No `SessionStart` hook in v0.1.0. Revisit if Codex cold-start latency turns out to be painful.
- **Per-model specializations.** No Haiku/Opus-style branches for GPT-5 vs GPT-4o vs others. Add only if a bench shows clear wins.
- **Async mode.** Same decision as the Claude Code version — synchronous on purpose, because the score needs to appear directly under the prompt.
- **Shared config.** No `~/.redpen.config`; each CLI has its own file. Revisit if users complain about duplicated `LANGUAGE`/`SHOW_HINT` settings.

## Open questions (for the reader)

1. Codex plugin marketplace: is `.claude-plugin/marketplace.json` reusable, or does Codex want its own `marketplace.json` format? Verify before publishing.
2. Does the plugin `commands/setup.md` actually get registered as `/redpen-codex:setup` when the plugin is installed, or do we need the `~/.codex/prompts/` symlink fallback? Verify before publishing.
3. The Claude Code version's Haiku optimization stack (`CLAUDE_CODE_DISABLE_THINKING=1` + few-shot examples) only made sense because Haiku 4.5 forced adaptive extended thinking. Does GPT-5-mini do anything analogous via `codex exec`? Bench before assuming the base prompt is enough.
