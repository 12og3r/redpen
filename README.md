# redpen

A personal agent CLI plugin that **marks up every prompt you type** like
a teacher with a red pen — scoring your phrasing, highlighting what's
broken, and showing how a native speaker would say the same thing — all
in your chosen target language. Designed for developers who want passive
writing practice while doing their day job at the terminal.

Currently supports two agent CLIs as separate but feature-parallel plugins,
plus an experimental launcher for Codex App:

- **Claude Code** — install [`redpen`](#install-claude-code)
- **OpenAI Codex CLI** — install [`redpen-codex`](#install-codex-cli)
- **Codex App** — run the lightweight launcher in
  [Codex App experimental launcher](#codex-app-experimental-launcher)

The two CLI plugins share the same architecture (UserPromptSubmit hook +
`systemMessage` emit), scoring rubric, target languages, and shared
`render_diff.py`. The Codex App launcher reuses the Codex runner but renders
feedback in the app DOM instead of a CLI hook channel. Your original prompt
always reaches the model unchanged — the feedback is shown to you only, never
added to the model's context. redpen is a **coach**, not a rewriter: the goal
is for you to read the correction, notice what was off, and write a little
better next time.

Supported languages (both plugins):

- **English**
- **中文 (Chinese)**
- **Español (Spanish)**
- **日本語 (Japanese)**

Each time you submit a prompt, the plugin scores your phrasing, shows a
corrected version with the changes diffed inline (red strikethrough for what
was removed, green for what was added), and (optionally) a "native style" line
showing how a native speaker would phrase the same thing:

```
You: help me fix the bug, the app crash when click button
redpen: [62] help me fix the bug — the app crashes when I click the button.
        ──── Native style ────
        any idea why the app crashes whenever I click that button?

The assistant then proceeds to answer your original prompt normally.
```

In Claude Code that's a three-line `systemMessage` block. In Codex CLI
the same content is rendered on a single line
(`[62] <rewrite> ▍native▍ <native style>`) because Codex's hook channel
is a one-line toast — see [Platform differences](#platform-differences).

The feedback is delivered via the host CLI's `systemMessage` channel
(supported by both Claude Code and Codex), so it's visible to you but
**never added to the model's context** — the assistant only ever sees
your original wording, and your conversation stays clean.

## Platform differences

The two plugins are feature-parallel, but each host CLI has its own
constraints:

| | Claude Code (`redpen`) | Codex CLI (`redpen-codex`) |
|---|---|---|
| Config | `~/.claude/redpen.config` | `~/.codex/redpen.config` |
| Default model | `haiku` (alias), user-configurable via `/redpen:setup` | `gpt-5.4-mini`, **locked in v0.3.0** (only model that works on ChatGPT-account Codex auth — edit `plugins/redpen-codex/hooks/grammar_check.sh` to override) |
| Setup invoke | `/redpen:setup` | `$redpen-setup` (Codex skill — TUI only) |
| Hook target | `claude -p` | `codex exec` |
| Output layout | multi-line (score / divider / native style) | single line (`[N] <text> ▍native▍ <native style>`, inverted-bg label as the visual break) — Codex's systemMessage channel is a single-line toast that strips all newlines |

The two configs live at independent paths (`~/.claude/redpen.config` vs
`~/.codex/redpen.config`), so both plugins can be installed side-by-side
without colliding.

## Install (Claude Code)

```sh
# 1. Register this repo as a marketplace
/plugin marketplace add 12og3r/redpen
# (https://github.com/12og3r/redpen also works)

# 2. Install the plugin
/plugin install redpen@redpen

# 3. Restart Claude Code so the UserPromptSubmit hook registers
```

## Install (Codex CLI)

```sh
# 1. Register this repo as a Codex marketplace
codex plugin marketplace add 12og3r/redpen

# 2. Install the Codex plugin (note the @redpen marketplace suffix)
codex plugin add redpen-codex@redpen
```

**Defaults**: out of the box (no config file), redpen-codex coaches in
**English** with the **native-style hint on**. Send any prompt and you
should see a `[NN] <rewrite>  →  <native-style>` line. No setup
required.

## Codex App experimental launcher

This path does not modify `Codex.app` or unpack `app.asar`. It launches a
fresh Codex App process with Chrome DevTools remote debugging enabled, injects
a small renderer script through CDP, and handles redpen checks through a
`Runtime.addBinding` bridge back to this launcher.

```sh
# Quit Codex App first, then run:
cargo run -p redpen-codex-app -- launch
```

For a released build, install the launcher with:

```sh
curl -fsSL https://github.com/12og3r/redpen/releases/latest/download/install-codex-app.sh | sh
```

Or download `redpen-codex-app-macos-universal` from the GitHub release page,
make it executable, and place it anywhere on your `PATH`.

The launcher reuses the Codex config at `~/.codex/redpen.config` and the same
`codex exec` runner as `redpen-codex`. Feedback appears asynchronously under
the just-submitted user message. Your original prompt is not changed, and the
feedback is not sent back into the conversation context.

Useful flags:

```sh
cargo run -p redpen-codex-app -- launch \
  --codex-app /Applications/Codex.app \
  --debug-port 9229
```

If Codex App is already running, the launcher exits with an instruction to
quit it first. This is intentional: an already-running Electron process may
ignore new remote-debugging arguments.

Release builds are single-file executables. The binary embeds the redpen
coach scripts and expands them under
`~/Library/Application Support/redpen-codex-app/runtime/<version>/` on first
run. Set `REDPEN_COACH_SCRIPT` or pass `--coach-script` only when debugging a
local script override.

## Configure (Claude Code)

Run the bundled setup command (after a session restart):

```
/redpen:setup
```

This asks three questions:

| Question | Choices |
|---|---|
| Language | `English` · `中文 (Chinese)` · `Español (Spanish)` · `日本語 (Japanese)` |
| Model    | `Haiku` (default, recommended) · `Sonnet` · `Opus` |
| Native style line | `On` (default, recommended) · `Off` |

The chosen values are written to `~/.claude/redpen.config`. You can also edit
that file by hand:

```
LANGUAGE=chinese
MODEL=haiku
SHOW_HINT=on
```

`MODEL` accepts the generic family aliases `haiku` / `sonnet` / `opus` —
`claude --model` resolves these to the latest released version, so this
config keeps working across Anthropic model releases without a plugin
update. Power users can also pin a specific version
(e.g. `MODEL=claude-haiku-4-5-20251001`) — any value `claude --model`
accepts will work. Pick `Other` in `/redpen:setup` to type a
custom value. Set `MODEL=` (empty) to follow whatever Claude Code's
`/model` is currently set to instead.

## Configure (Codex CLI)

In a Codex TUI session, type:

```
$redpen-setup
```

The skill walks two numbered questions:

| Question | Choices |
|---|---|
| Language | `English` · `中文 (Chinese)` · `Español (Spanish)` · `日本語 (Japanese)` |
| Native style line | `On` (default, recommended) · `Off` |

The chosen values are written to `~/.codex/redpen.config`. (Model is
locked to `gpt-5.4-mini` in v0.3.0, so the skill doesn't ask about it —
see [Codex CLI — known limitations](#codex-cli--known-limitations) for
how to override.)

You can also edit `~/.codex/redpen.config` by hand (just 2 lines — see
the example in [plugins/redpen-codex/skills/setup/SKILL.md](plugins/redpen-codex/skills/setup/SKILL.md));
this is the only route in non-TUI `codex exec` since skills don't fire
there.

## Codex CLI — known limitations

- **Single-line output only.** Codex's `systemMessage` hook channel renders
  as a single-line warning toast that strips newlines (verified empirically
  — `\n`, `\n\n`, `\r`, `<br>`, U+2028, markdown hard break, all collapse).
  The Codex plugin therefore renders the score, divider, and native-style
  hint on one line with a `→` separator. Claude Code keeps its richer
  three-line layout.
- **Model is locked to `gpt-5.4-mini` in v0.3.0.** Empirically, it's the
  only model that works on the default ChatGPT-account Codex auth —
  `gpt-4o-mini` / `gpt-5-mini` / `gpt-5` / `gpt-5-codex` all return
  `model not supported`. The `redpen-setup` skill therefore doesn't ask
  about model. To override (e.g. when running with `OPENAI_API_KEY`),
  edit the `MODEL=` line in
  `plugins/redpen-codex/hooks/grammar_check.sh` directly.
- **Skills are TUI-only.** The `$redpen-setup` skill only fires inside the
  interactive Codex TUI. In `codex exec` non-interactive mode the skill
  invocation does nothing; users on that path should edit
  `~/.codex/redpen.config` by hand instead.
- **No `--no-tools` analog in `codex exec`** — tool definitions still
  inflate the prompt context (~5–7k tokens observed) vs. the Claude Code
  version. Latency and cost are higher per coach turn. Stick with
  `gpt-5.4-mini` (the default) if you care about cost.
- **`codex exec` flag stack is empirical**. We use `--ephemeral`,
  `--ignore-user-config`, `--ignore-rules`, `--skip-git-repo-check`,
  `--sandbox read-only`, `-c model_reasoning_effort=low`. The combination
  works on Codex 0.133.0 + ChatGPT-account auth (verified end-to-end
  manually). If something is slow on your machine, file an issue with
  timings.
- **Latency floor is ~5s per coach turn.** Empirically measured on
  Codex 0.133.0 + ChatGPT-account auth + gpt-5.4-mini. Breakdown: codex
  CLI startup ~50ms, the rest is OpenAI network + model inference and
  is per-call. Unlike the Claude Code version (where SessionStart
  prewarm caches V8 bytecode and saves ~5s per call), there's nothing
  to prewarm here — `codex exec` doesn't have CLI-level overhead to
  amortize. `-c model_reasoning_effort=minimal` is faster (~3s) but
  produces empty output (verified — model refuses to generate at that
  effort level), so unusable. Routes for faster turnaround if you need
  it: switch to `OPENAI_API_KEY` auth + direct API call (bypass the
  codex wrapper), or run a local model via `--oss --local-provider
  ollama` (loses quality).

## Developing

Each plugin bundles its own `shared/` directory (`coach_prompts.sh`,
`render_diff.py`) so marketplace installs are self-contained — the installer
copies a single plugin directory and a sibling `shared/` would not come
along. The three plugins (`redpen`, `redpen-codex`, `redpen-coco`) maintain
their `shared/` copies **independently**: there is no canonical source and no
sync step, so each plugin can diverge where its host CLI needs it (e.g. coco
skips the leading newline its TUI already adds). When fixing a bug that
affects more than one plugin, apply the change to each plugin's copy by hand.

## Scoring rubric

The model scores your original prompt on a 0–100 scale:

| Score | Meaning |
|---|---|
| **100** | Already perfect, natural, idiomatic |
| 80–99   | Minor polish (article / preposition / tense slips) |
| 50–79   | Understandable but with clear grammar or word-choice errors |
| 1–49    | Broken, hard to read |
| **0**   | Contains ANY character from a non-target language (even one foreign letter forces 0, regardless of the rest) |

The correction always runs — even on score 0 — so you always see a
target-language version, even when your input was in a different language.
Brand names, file paths, code identifiers, and function names are preserved
verbatim.

## What gets skipped

To avoid burning model calls on inputs that aren't natural-language prose:

- Empty prompts
- Pure slash commands (e.g. `/help`) — when a slash command is followed by
  space-separated args, those args ARE coached
- (Codex only) Pure skill invocations (e.g. `$redpen-setup`) — same args
  rule as slash commands; the `$cmd <text>` form coaches just the args
- Shell passthroughs (`!ls`, `!ls -la`)
- Prompts longer than `MAX_PROMPT_CHARS` characters (default `2000`). The
  UserPromptSubmit hook doesn't receive paste metadata from the host CLI, so
  we can't surgically separate user-typed prose from pasted code, logs, or
  transcripts. Length is the simplest reliable proxy — long prompts almost
  always contain paste we don't want to rewrite. Tune via env var or by
  adding `MAX_PROMPT_CHARS=<n>` to your `redpen.config` (the Claude Code
  plugin reads `~/.claude/redpen.config`; the Codex plugin reads
  `~/.codex/redpen.config`).

## How it works (Claude Code)

The Codex CLI version follows the same shape (UserPromptSubmit hook
spawns `codex exec`, parses output, emits `systemMessage`); see
`plugins/redpen-codex/hooks/grammar_check.sh` for its exact flag stack.

```
┌─────────────────────────────────────────────────────────┐
│ You submit a prompt in Claude Code                      │
└──────────────────────┬──────────────────────────────────┘
                       ▼
              UserPromptSubmit hook fires
                       │
                       ▼
        ┌─────────────────────────────────────────┐
        │ Strip /cmd token if present             │
        │ Skip empty / shell / pure-slash prompts │
        └─────────┬───────────────────────────────┘
                  ▼
   Spawn `claude -p` from $TMPDIR with the
   minimal-startup flag stack:
   • --system-prompt = coach instructions
   • --setting-sources ""        no user/proj/local settings
   • --strict-mcp-config         skip default MCP config
   • --mcp-config '{...}'        empty MCP config
   • --no-session-persistence    no transcript .jsonl
   • --tools ""                  no tool defs (drops ~11k input tokens)
   • --effort low                skip the model's internal thinking block
   • </dev/null                  skip 3s stdin wait
   + CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
   + CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
   + CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
   + CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1
   + REDPEN_ACTIVE=1  (recursion guard)
                  │
                  ▼
        Receive "[NN] <rewrite>"
                  │
                  ▼
   Emit JSON {"systemMessage": "\n[NN] <rewrite>"}
                  │
                  ▼
   Claude Code displays it inline to you;
   parent conversation context is unchanged.
```

Key design choices:

- **Synchronous on purpose.** An earlier iteration tried async (UserPromptSubmit
  forks a detached worker → Stop hook drains a queue file when Claude finishes
  responding). It worked but the score appeared in unpredictable positions —
  far below the original prompt, sometimes interleaved with tool output.
  Reverting to a blocking call keeps the score pinned directly under your
  prompt where you can compare side-by-side.
- **`--system-prompt` replaces** the default Claude Code system prompt so the
  coach instructions aren't diluted.
- The minimal-startup flag stack + env vars cut `claude -p` overhead roughly
  in half on the OAuth/Pro auth path (none of these flags require an API key
  — `--bare` would, but it'd break for subscription users). The single
  biggest win is `</dev/null` redirecting stdin, which kills a hard-coded
  3-second wait inside `claude -p`.
- The headless call runs from `$TMPDIR` / `/tmp` / `$HOME` (first that exists)
  to escape project-level `CLAUDE.md` and auto-loaded skills (e.g.
  `superpowers:systematic-debugging` would otherwise hijack "fix the bug"
  prompts).
- `--no-session-persistence` means no `.jsonl` transcript ever gets written,
  so we don't need `--session-id` tracking or a cleanup pass.

## Limitations (Claude Code)

(For Codex-specific limitations see [Codex CLI — known limitations](#codex-cli--known-limitations) above.)

- Adds ~1–3s of latency before your prompt reaches the model (median ~1.2s
  with Haiku, ~2.2s with Sonnet, on the OAuth/Pro auth path, measured over a
  35-prompt bench varying from 7 to 523 chars). Latency scales mildly with
  prompt length.
- **Haiku gets a special-case optimization stack.** Haiku 4.5 forces adaptive
  extended thinking even with `--effort low` — out of the box, median latency
  is 9s (p95 32s) and output explodes to 742 tokens median (p95 3771). When
  `MODEL=haiku*`, the hook sets `CLAUDE_CODE_DISABLE_THINKING=1` and appends
  a visible `ANALYSIS:` reasoning line plus ~20 few-shot examples to the
  system prompt. That collapses median latency to ~1.2s (p95 2.8s) and
  median output to 60 tokens, while keeping the false-zero rate at 0/100
  (a naked `DISABLE_THINKING` causes Haiku to misjudge ~5% of clean English
  as score 0). The few-shot examples push the system prompt past Haiku
  4.5's ~4096-token prompt-cache threshold, so subsequent calls within the
  cache window hit `cache_read` and pay 10% of input cost. Net result:
  Haiku is the cheapest and fastest option for this task — 61% cheaper
  than its uncached form, 47% cheaper than Sonnet, and 26% faster than
  Sonnet on p80 latency.
- **Opus gets a slim system prompt + Sonnet fallback.** When `MODEL=opus*`
  and `LANGUAGE=english`, the hook swaps to a 4× shorter system prompt
  (the verbose nuance / examples don't help Opus 4.7 follow the rules).
  Bench: -62% cost, -34% p95 latency, -56% max latency, 0 false-zeros.
  It also passes `--fallback-model sonnet` so when Opus is queue-overloaded
  (the cause of its p95 long tail — not hidden thinking, which is already
  off at `--effort low`) the request falls through to Sonnet rather than
  wait. Quality is preserved because Sonnet is Opus-quality on this task.
- Costs ~$0.002–0.006 per call. With `--tools ""` the input drops below
  Sonnet's prompt-cache threshold for English/Spanish (so no caching, but
  also no cache-creation premium). Longer system prompts like Chinese/Japanese
  still trigger caching automatically.
- Spanish vs English vs other Latin-script languages are not character-level
  distinguishable; for Spanish mode, the model decides Spanish-ness from
  vocabulary and grammar.
- The `systemMessage` field is read but discarded by some pipe-based tools;
  the feedback only renders in interactive Claude Code sessions.

## Files

```
redpen/
├── README.md                                ← this file
├── LICENSE
├── .claude-plugin/marketplace.json          ← Claude Code marketplace entry
├── .agents/plugins/marketplace.json         ← Codex CLI marketplace entry
├── plugins/redpen/                          ← Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── commands/setup.md                    ← /redpen:setup
│   ├── shared/                              ← coach_prompts.sh + render_diff.py (self-contained)
│   └── hooks/
│       ├── hooks.json                       ← UserPromptSubmit registration
│       └── grammar_check.sh                 ← the hook itself
├── plugins/redpen-codex/                    ← Codex CLI plugin
│   ├── .codex-plugin/plugin.json
│   ├── skills/setup/SKILL.md                ← $redpen-setup
│   ├── shared/                              ← own copy (also embedded in redpen-codex-app)
│   └── hooks/
│       ├── hooks.json
│       └── grammar_check.sh
└── plugins/redpen-coco/                     ← coco CLI plugin (own shared/ copy)
```

Each plugin's `shared/` is maintained independently — there is no canonical
copy and no sync step (see [Developing](#developing)).

User-level files (created on first run):

- `~/.claude/redpen.config` — Claude Code plugin: language + model + hint
- `~/.claude/redpen.log` — Claude Code plugin debug log (rotates manually)
- `~/.codex/redpen.config` — Codex plugin: language + hint (model is locked)
- `~/.codex/redpen.log` — Codex plugin debug log

## License

MIT — see `LICENSE`.

## Acknowledgements

Inspired by [jiang1997/claude-code-language-coach](https://github.com/jiang1997/claude-code-language-coach)
— thanks to the original author for the idea of using a UserPromptSubmit hook
to coach the user's writing inside Claude Code.
