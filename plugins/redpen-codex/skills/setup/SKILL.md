---
name: redpen-setup
description: Configure the redpen-codex plugin (language + model + native-style hint). Invoke when the user first installs redpen-codex, or any time they want to change which language they are practising or which OpenAI model the plugin uses for coaching. Writes ~/.codex/redpen.config.
allowed-tools: Read, Write
---

The user invoked the redpen-setup skill. Follow these steps EXACTLY. Do not
explore the codebase, do not run other commands, do not summarise.

## Step 1 — Read current config

Read `~/.codex/redpen.config`. Parse:
- `LANGUAGE=<...>` (default: `english`)
- `MODEL=<...>` (default: `gpt-4o-mini`)
- `SHOW_HINT=<on|off>` (default: `on`)

Remember as `CURRENT_LANGUAGE`, `CURRENT_MODEL`, `CURRENT_SHOW_HINT`.

**First-run case:** if the config file does NOT exist (this is the user's
first time running setup), treat `CURRENT_LANGUAGE`, `CURRENT_MODEL`, and
`CURRENT_SHOW_HINT` as ALL UNSET — do NOT substitute defaults for the
purpose of the current-selection marker in Step 2. The defaults above only
apply when writing the config in Step 4 if the user picks Other / blank.
When the config is unset, no option should be marked with ✓.

## Step 2 — Ask the user (three questions, one at a time)

Ask Question 1 and wait for the user's reply. Only after they reply, ask
Question 2. Only after they reply to Question 2, ask Question 3. Do NOT
batch the three questions into one turn — the user needs to see and answer
each one independently.

**Current-selection marker:** append ` ✓` to the option whose value
matches the user's current config — this shows them what they're on. The ✓
is independent of `(Recommended)`; both can appear together. When matching
the user's answer in Step 3, ignore any trailing ` ✓`.

**Question 1 — language**

Which language do you want the redpen plugin to coach you on?

Options (only these four; if the user picks something else, fall back to English):
- `English` — Practise English. Plugin rewrites English prompts.
- `中文 (Chinese)` — Practise Chinese. Plugin rewrites Chinese prompts.
- `Español (Spanish)` — Practise Spanish. Plugin rewrites Spanish prompts.
- `日本語 (Japanese)` — Practise Japanese. Plugin rewrites Japanese prompts.

**Question 2 — model**

Which OpenAI model should the plugin use for rewriting? Pick a family below,
or type a specific model id (e.g. gpt-5.4, gpt-5.3-Codex) if you want to pin
one.

Options (ALWAYS append ` (Recommended)` to `gpt-4o-mini`, regardless of
`CURRENT_MODEL`. gpt-4o-mini is the cheapest+fastest documented option for
this task; do NOT use `(Recommended)` as a state marker):
- `gpt-4o-mini` — Cheapest and fastest documented OpenAI model. Best fit for the coaching task.
- `gpt-5-mini` — Newer family. May not be available on all accounts; falls through silently if so.
- `gpt-5` — Smarter; higher latency and cost.
- Other — type any model id `codex exec --model` accepts (e.g. `gpt-5.4`, `gpt-5.3-Codex`).

**Question 3 — native style line**

Show a second "native style" line with a more idiomatic rephrasing under
each rewrite?

Options (ALWAYS append ` (Recommended)` to `On`):
- `On` — Show the divider + native-style rephrasing line under each rewrite.
- `Off` — Only show the scored rewrite line. No second line.

## Step 3 — Map answers to config values

Language:
- `English` → `english`
- `中文 (Chinese)` → `chinese`
- `Español (Spanish)` → `spanish`
- `日本語 (Japanese)` → `japanese`
- Anything else → `english`

Model:
- `gpt-4o-mini ...` → `gpt-4o-mini`
- `gpt-5-mini ...` → `gpt-5-mini`
- `gpt-5 ...` (but NOT `gpt-5-mini`) → `gpt-5`
- `Other` with a typed value → the typed value verbatim, whitespace-trimmed
- `Other` with empty input → `gpt-4o-mini`

Native hint:
- `On ...` → `on`
- `Off ...` → `off`
- Anything else → `on`

## Step 4 — Write the new config

Use the Write tool to overwrite `~/.codex/redpen.config` with EXACTLY this
content (substitute the chosen values):

```
# redpen-codex plugin config — sourced by the UserPromptSubmit hook.
#
# Supported LANGUAGE values:
#   english | chinese | spanish | japanese
#   aliases: en | zh, cn, 中文 | es, español, espanol | ja, jp, 日本語
LANGUAGE=<new language>
#
# MODEL: any value `codex exec --model` accepts. The two recommended
# defaults are:
#   gpt-4o-mini  — cheapest and fastest documented option (recommended)
#   gpt-5-mini   — newer; may not be available on all accounts
# You can also pin a specific version explicitly, e.g.
#   MODEL=gpt-5.4
# Leave empty (MODEL=) to follow whatever Codex's default model is.
MODEL=<new model>
#
# SHOW_HINT: whether to show a second "native style" line under each rewrite
# with a more idiomatic, colloquial rephrasing. on (default) | off.
SHOW_HINT=<new show_hint>
```

## Step 5 — Confirm

Reply with ONE short line summarising what changed. Examples:
- Both changed: `✓ Switched to 中文 with gpt-5.`
- Only language: `✓ Language set to English (model unchanged: gpt-4o-mini).`
- Only model: `✓ Model set to gpt-5 (language unchanged: English).`
- Custom model: `✓ Model set to gpt-5.4 (language unchanged: English).`
- Nothing changed: `Already on English + gpt-4o-mini — no change.`

New setting takes effect on your next prompt. No further explanation.
