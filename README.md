# language-tutor

A personal Claude Code plugin that **scores and rewrites every user prompt** in
your chosen target language. Designed for developers who want passive
writing practice while doing their day job in Claude Code.

Supported languages:

- **English**
- **中文 (Chinese)**
- **Español (Spanish)**

Each time you submit a prompt, the plugin sends it to a headless `claude -p`
call with a strict "coach" system prompt, then displays the result inline:

```
You: help me fix the bug, the app crash when click button
language-tutor: [62] Help me fix the bug — the app crashes when I click the button.

Claude proceeds to answer your *original* prompt normally.
```

The feedback is shown via Claude Code's `systemMessage` channel, so it's
visible to you but **never added to the model's context** — your conversation
stays clean.

## Install

```sh
# 1. Register this repo as a marketplace
/plugin marketplace add 12og3r/language-tutor
# (https://github.com/12og3r/language-tutor also works)

# 2. Install the plugin
/plugin install language-tutor@language-tutor

# 3. Restart Claude Code so the UserPromptSubmit hook registers
```

## Configure

Run the bundled setup command (after a session restart):

```
/language-tutor:setup
```

This asks two questions:

| Question | Choices |
|---|---|
| Language | `English` · `中文 (Chinese)` · `Español (Spanish)` |
| Model    | `Haiku 4.5` · `Sonnet 4.6` · `Opus 4.7` |

The chosen values are written to `~/.language-tutor.config`. You can also edit
that file by hand:

```
LANGUAGE=chinese
MODEL=claude-sonnet-4-6
```

Set `MODEL=` (empty) to follow whatever Claude Code's `/model` is currently
set to instead of pinning a specific model.

## Scoring rubric

The model scores your original prompt on a 0–100 scale:

| Score | Meaning |
|---|---|
| **100** | Already perfect, natural, idiomatic |
| 80–99   | Minor polish (article / preposition / tense slips) |
| 50–79   | Understandable but with clear grammar or word-choice errors |
| 1–49    | Broken, hard to read |
| **0**   | Contains ANY character from a non-target language (even one foreign letter forces 0, regardless of the rest) |

The rewrite always runs — even on score 0 — and produces target-language
output while preserving brand names, file paths, code identifiers, and
function names verbatim.

## What gets skipped

To avoid burning model calls on inputs that aren't natural-language prose:

- Empty prompts
- Pure slash commands (e.g. `/help`) — when a slash command is followed by
  space-separated args, those args ARE coached
- Shell passthroughs (`!ls`, `!ls -la`)

## How it works

```
┌─────────────────────────────────────────────────────────┐
│ You submit a prompt in Claude Code                      │
└──────────────────────┬──────────────────────────────────┘
                       ▼
              UserPromptSubmit hook fires
                       │
                       ▼
        ┌─────────────────────────────┐
        │ Strip /cmd token if present │
        │ Skip empty / shell prefixes │
        └─────────┬───────────────────┘
                  ▼
   Spawn `claude -p` from $TMPDIR with:
   • --system-prompt = coach instructions
   • --model = your configured model
   • LANGUAGE_TUTOR_ACTIVE=1 (recursion guard)
                  │
                  ▼
        Receive "[NN] <rewrite>"
                  │
                  ▼
   Delete the headless session transcript
                  │
                  ▼
   Emit JSON {"systemMessage": "\n[NN] <rewrite>"}
                  │
                  ▼
   Claude Code displays it inline to you;
   the parent conversation context is unchanged.
```

Key design choices:

- **`--system-prompt` replaces** the default Claude Code system prompt so the
  coach instructions aren't diluted.
- The headless call runs from `$TMPDIR` / `/tmp` / `$HOME` (first that exists)
  to escape project-level `CLAUDE.md` and auto-loaded skills (e.g.
  `superpowers:systematic-debugging` would otherwise hijack "fix the bug"
  prompts).
- Each call uses a fresh UUID `--session-id`; the resulting transcript file
  under `~/.claude/projects/` is deleted immediately after the call so they
  don't accumulate.

## Limitations

- Adds ~1–3 seconds of latency before your prompt reaches the model (Haiku
  round-trip).
- Costs a Haiku call per prompt (~$0.0001 each at current pricing).
- Spanish vs English vs other Latin-script languages are not character-level
  distinguishable; for Spanish mode, the model decides Spanish-ness from
  vocabulary and grammar.
- The `systemMessage` field is read but discarded by some pipe-based tools;
  the feedback only renders in interactive Claude Code sessions.

## Files

```
language-tutor/
├── README.md                                ← this file
├── LICENSE
├── .claude-plugin/marketplace.json
└── plugins/language-tutor/
    ├── .claude-plugin/plugin.json
    ├── commands/setup.md                    ← /language-tutor:setup
    └── hooks/
        ├── hooks.json                       ← UserPromptSubmit registration
        └── grammar_check.sh                 ← the hook itself
```

User-level files (created on first run):

- `~/.claude/language-tutor.config` — language + model
- `~/.claude/language-tutor.log` — debug log (rotates manually)

## License

MIT — see `LICENSE`.
