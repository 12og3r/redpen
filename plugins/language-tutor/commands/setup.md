---
description: Configure the language-tutor plugin (language + model).
allowed-tools: Read, Write, AskUserQuestion
---

The user invoked `/language-tutor:setup`. Follow these steps EXACTLY. Do not
explore the codebase, do not run other commands, do not summarise.

## Step 1 — Read current config

Read `~/.claude/language-tutor.config`. Parse:
- `LANGUAGE=<...>` (default: `english`)
- `MODEL=<...>` (default: `haiku`)

Remember as `CURRENT_LANGUAGE` and `CURRENT_MODEL`.

## Step 2 — Ask the user (single AskUserQuestion call, two questions)

Call `AskUserQuestion` ONCE with both questions:

**Question 1 — language**
- question: `Which language do you want the language-tutor plugin to coach you on?`
- header: `Language`
- multiSelect: false
- options (only these three; if user picks the auto-added Other, fall back to English):
  - `English` — Practise English. Plugin rewrites English prompts.
  - `中文 (Chinese)` — Practise Chinese. Plugin rewrites Chinese prompts.
  - `Español (Spanish)` — Practise Spanish. Plugin rewrites Spanish prompts.

(AskUserQuestion auto-appends an `Other` option. If the user picks it and types
a value, IGNORE the value and treat it as `English` — this plugin only supports
the three languages above.)

**Question 2 — model**
- question: `Which Claude model should the plugin use for rewriting?`
- header: `Model`
- multiSelect: false
- options (exactly these three, in this order; append ` (Recommended)` to whichever
  one matches `CURRENT_MODEL` so the user can see what is currently selected):
  - `Haiku` — Fast and cheap. Good enough for grammar rewriting.
  - `Sonnet` — Balanced quality, cost, and latency.
  - `Opus` — Smartest, slowest, most expensive.

(AskUserQuestion will auto-append an `Other` option. If the user picks it and
types a value, IGNORE the value and treat it as `Haiku` — this plugin
only supports the three Anthropic model families above.)

## Step 3 — Map answers to config values

Language:
- `English` → `english`
- `中文 (Chinese)` → `chinese`
- `Español (Spanish)` → `spanish`
- `Other` (any custom value the user typed) → `english` — this plugin only
  supports English, Chinese, and Spanish; ignore whatever string the user typed.

Model:
- `Haiku ...` → `haiku`
- `Sonnet ...` → `sonnet`
- `Opus ...` → `opus`
- `Other` (any custom value) → `haiku` — this plugin only supports the three
  Anthropic model families above.

These are the generic family aliases that `claude --model` accepts; Anthropic
resolves them to the latest released version of that family, so this plugin
doesn't need a re-release whenever a new Haiku/Sonnet/Opus ships.

## Step 4 — Write the new config

Use `Write` to overwrite `~/.claude/language-tutor.config` with EXACTLY this
content (substitute the chosen values):

```
# language-tutor plugin config — sourced by the UserPromptSubmit hook.
#
# Supported LANGUAGE values:
#   english | chinese | spanish
#   aliases: en | zh, cn, 中文 | es, español, espanol
LANGUAGE=<new language>
#
# MODEL: one of the generic family aliases. claude --model resolves these to
# the latest released version of each family, so this config keeps working
# across Anthropic model releases without a plugin update.
#   haiku    — fast & cheap (default)
#   sonnet   — balanced
#   opus     — smartest
# Leave empty (MODEL=) to follow whatever Claude Code's /model is set to.
MODEL=<new model>
```

## Step 5 — Confirm

Reply with ONE short line summarising what changed, using the human label, e.g.:
- Both changed: `✓ Switched to 中文 with Sonnet.`
- Only language: `✓ Language set to English (model unchanged: Haiku).`
- Only model: `✓ Model set to Opus (language unchanged: English).`
- Nothing changed: `Already on English + Haiku — no change.`

New setting takes effect on your next prompt. No further explanation.
