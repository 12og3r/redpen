# redpen

A personal Claude Code plugin that **marks up every prompt you type** like a
teacher with a red pen — scoring your phrasing, highlighting what's broken,
and showing how a native speaker would say the same thing — all in your chosen
target language. Designed for developers who want passive writing practice
while doing their day job in Claude Code.

Your original prompt always reaches the model unchanged. The feedback is shown
to you only — Claude proceeds to answer what you actually typed. redpen is a
**coach**, not a rewriter: the goal is for you to read the correction, notice
what was off, and write a little better next time.

Supported languages:

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

Claude proceeds to answer your original prompt normally.
```

The feedback is delivered via Claude Code's `systemMessage` channel, so it's
visible to you but **never added to the model's context** — Claude only ever
sees your original wording, and your conversation stays clean.

## Install

```sh
# 1. Register this repo as a marketplace
/plugin marketplace add 12og3r/redpen
# (https://github.com/12og3r/redpen also works)

# 2. Install the plugin
/plugin install redpen@redpen

# 3. Restart Claude Code so the UserPromptSubmit hook registers
```

## Configure

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
- Shell passthroughs (`!ls`, `!ls -la`)
- Prompts longer than `MAX_PROMPT_CHARS` characters (default `2000`). The
  UserPromptSubmit hook doesn't receive paste metadata from Claude Code, so
  we can't surgically separate user-typed prose from pasted code, logs, or
  transcripts. Length is the simplest reliable proxy — long prompts almost
  always contain paste we don't want to rewrite. Tune via env var or by
  adding `MAX_PROMPT_CHARS=<n>` to `~/.claude/redpen.config`.

## How it works

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

## Limitations

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
├── .claude-plugin/marketplace.json
└── plugins/redpen/
    ├── .claude-plugin/plugin.json
    ├── commands/setup.md                    ← /redpen:setup
    └── hooks/
        ├── hooks.json                       ← UserPromptSubmit registration
        └── grammar_check.sh                 ← the hook itself
```

User-level files (created on first run):

- `~/.claude/redpen.config` — language + model
- `~/.claude/redpen.log` — debug log (rotates manually)

## License

MIT — see `LICENSE`.

## Acknowledgements

Inspired by [jiang1997/claude-code-language-coach](https://github.com/jiang1997/claude-code-language-coach)
— thanks to the original author for the idea of using a UserPromptSubmit hook
to coach the user's writing inside Claude Code.
