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
- `MODEL=<...>` (default: `gpt-5.4-mini`)
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
or type a specific model id if you want to pin one.

**IMPORTANT auth note:** If the user logs into Codex with a ChatGPT account
(the default for `codex auth login`), only the `gpt-5.4` family models work
— `gpt-4o-mini` / `gpt-5-mini` / `gpt-5` / `gpt-5-codex` all return
"model not supported" on ChatGPT auth. If the user has an OpenAI API key
(`OPENAI_API_KEY` set), all models are available. Default and recommend
`gpt-5.4-mini` since it works in both modes.

Options (ALWAYS append ` (Recommended)` to `gpt-5.4-mini`, regardless of
`CURRENT_MODEL`; do NOT use `(Recommended)` as a state marker):
- `gpt-5.4-mini` — Works on both ChatGPT-account and API-key Codex auth. Cheapest available option for ChatGPT-account users.
- `gpt-5.4` — Higher quality, slower; same auth requirements as gpt-5.4-mini.
- `gpt-4o-mini` — Older but cheaper. **Requires `OPENAI_API_KEY` — fails on ChatGPT-account auth.**
- Other — type any model id `codex exec --model` accepts (e.g. `gpt-5-mini`, `gpt-5-codex`).

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
- `gpt-5.4-mini ...` → `gpt-5.4-mini`
- `gpt-5.4 ...` (but NOT `gpt-5.4-mini`) → `gpt-5.4`
- `gpt-4o-mini ...` → `gpt-4o-mini`
- `Other` with a typed value → the typed value verbatim, whitespace-trimmed
- `Other` with empty input → `gpt-5.4-mini`

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
# MODEL: any value `codex exec --model` accepts. Recommended:
#   gpt-5.4-mini  — cheapest model available to ChatGPT-account auth (default)
#   gpt-5.4       — higher quality, same auth scope
#   gpt-4o-mini   — cheaper but REQUIRES an OPENAI_API_KEY; fails on
#                   ChatGPT-account auth with "model not supported"
# Other ids (gpt-5-mini, gpt-5, gpt-5-codex) require an API key too.
# Leave empty (MODEL=) to follow whatever Codex's default model is.
MODEL=<new model>
#
# SHOW_HINT: whether to show a second "native style" line under each rewrite
# with a more idiomatic, colloquial rephrasing. on (default) | off.
SHOW_HINT=<new show_hint>
```

## Step 5 — Confirm

Reply with ONE short line summarising what changed. Examples:
- Both changed: `✓ Switched to 中文 with gpt-5.4.`
- Only language: `✓ Language set to English (model unchanged: gpt-5.4-mini).`
- Only model: `✓ Model set to gpt-5.4 (language unchanged: English).`
- Custom model: `✓ Model set to gpt-5-codex (language unchanged: English).`
- Nothing changed: `Already on English + gpt-5.4-mini — no change.`

New setting takes effect on your next prompt. No further explanation.
