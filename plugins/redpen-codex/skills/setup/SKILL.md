---
name: redpen-setup
description: Configure the redpen-codex plugin (language + native-style hint). Invoke when the user wants to change which language they are practising or whether the native-style hint shows. Writes ~/.codex/redpen.config.
allowed-tools: Read, Write
---

The user invoked the redpen-setup skill. Follow these steps EXACTLY. Do not
explore the codebase, do not run other commands, do not summarise.

> **Note on model:** v0.1.0 locks the OpenAI model to `gpt-5.4-mini` — the
> only model verified to work on ChatGPT-account Codex auth (the default
> `codex auth login` mode). The setup skill therefore does NOT ask about
> model. To override (e.g. when running with `OPENAI_API_KEY` set), edit
> the `MODEL=` line directly in `plugins/redpen-codex/hooks/grammar_check.sh`.

## Step 1 — Read current config

Read `~/.codex/redpen.config`. Parse:
- `LANGUAGE=<...>` (default: `english`)
- `SHOW_HINT=<on|off>` (default: `on`)

Remember as `CURRENT_LANGUAGE` and `CURRENT_SHOW_HINT`.

**Missing-config case:** if the file does not exist yet, treat both as
unset (no `✓` markers in Step 2). The defaults above only apply if the
user picks an out-of-range answer in Step 3.

## Step 2 — Ask the user (two questions, one at a time)

Ask Question 1 and wait for the user's reply. Only after they reply, ask
Question 2. Do NOT batch the two questions into one turn — the user needs
to see and answer each one independently.

**Current-selection marker:** append ` ✓` to the option whose value
matches the user's current config (so they see what they're on). The ✓
is independent of `(Recommended)`; both can appear together. When matching
the answer in Step 3, accept EITHER the number OR the label, and ignore
any trailing ` ✓`.

**Question 1 — language**

Reply with the number or the name. Which language do you want the redpen
plugin to coach you on?

1. `English`
2. `中文 (Chinese)`
3. `Español (Spanish)`
4. `日本語 (Japanese)`

**Question 2 — native style line**

Reply with the number or the name. Show a second "native style" line with
a more idiomatic rephrasing under each rewrite?

1. `On` (Recommended) — show the divider + native-style rephrasing.
2. `Off` — only show the scored rewrite line.

## Step 3 — Map answers to config values

Language (accept number OR name, case-insensitive, ignore trailing ✓):
- `1` or `English` → `english`
- `2` or `中文` / `Chinese` / `中文 (Chinese)` → `chinese`
- `3` or `Español` / `Spanish` / `Español (Spanish)` → `spanish`
- `4` or `日本語` / `Japanese` / `日本語 (Japanese)` → `japanese`
- Anything else → `english`

Native hint (accept number OR name, case-insensitive):
- `1` or `On` → `on`
- `2` or `Off` → `off`
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
# SHOW_HINT: whether to show a second "native style" line under each rewrite
# with a more idiomatic, colloquial rephrasing. on (default) | off.
SHOW_HINT=<new show_hint>
#
# NOTE: MODEL is locked to gpt-5.4-mini in v0.1.0 (the only model that
# works on ChatGPT-account Codex auth). To override, edit the MODEL= line
# in plugins/redpen-codex/hooks/grammar_check.sh directly.
```

## Step 5 — Confirm

Reply with ONE short line summarising what changed. Examples:
- Both changed: `✓ Switched to 中文 with native-style hints off.`
- Only language: `✓ Language set to English (hints unchanged: on).`
- Only hint: `✓ Native-style hints off (language unchanged: English).`
- Nothing changed: `Already on English + hints on — no change.`

New setting takes effect on your next prompt. No further explanation.
