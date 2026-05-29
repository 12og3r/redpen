---
name: redpen-setup
description: Configure the redpen-codex plugin (language, native-style hint, and Fast Mode). Invoke when the user wants to change which language they are practising, whether the native-style hint shows, or whether Codex Fast Mode is used for redpen's headless checks. Writes ~/.codex/redpen.config.
allowed-tools: Read, Write
---

The user invoked the redpen-setup skill. Follow these steps EXACTLY. Do not
explore the codebase, do not run other commands, do not summarise.

> **Note on model:** redpen-codex defaults to `gpt-5.4-mini`, which is the
> cheapest and fastest verified model for this lightweight coaching task. The
> setup skill does NOT ask about model. Advanced users can set `MODEL=gpt-5.4`
> or another `codex exec --model` value in `~/.codex/redpen.config`; setup
> preserves that existing value.

## Step 1 — Read current config

Read `~/.codex/redpen.config`. Parse:
- `LANGUAGE=<...>` (default: `english`)
- `SHOW_HINT=<on|off>` (default: `on`)
- `FAST_MODE=<on|off>` (default: `on`)
- `MODEL=<...>` (default: `gpt-5.4-mini`; preserve current value, do not ask)

Remember as `CURRENT_LANGUAGE`, `CURRENT_SHOW_HINT`, `CURRENT_FAST_MODE`, and
`CURRENT_MODEL`.

**Missing-config case:** if the file does not exist yet, treat all values as
unset (no `✓` markers in Step 2). The defaults above only apply if the user
picks an out-of-range answer in Step 3.

## Step 2 — Ask the user (three questions, one at a time)

Ask Question 1 and wait for the user's reply. Only after they reply, ask
Question 2. Only after they reply, ask Question 3. Do NOT batch the questions
into one turn — the user needs to see and answer each one independently.

**Current-selection marker:** append ` ✓` to the option whose value matches
the user's current config (so they see what they're on). The ✓ is independent
of `(Recommended)`; both can appear together. When matching the answer in Step
3, accept EITHER the number OR the label, and ignore any trailing ` ✓`.

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

**Question 3 — Fast Mode**

Reply with the number or the name. Use Codex Fast Mode for redpen's
background `codex exec` checks when the active Codex model supports it?

1. `On` (Recommended) — request Codex's Fast service tier for Fast-capable models; unsupported models run Standard.
2. `Off` — always use Standard service tier.

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

Fast Mode (accept number OR name, case-insensitive):
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
# MODEL: advanced override for redpen's background `codex exec --model` value.
# The setup skill preserves the current value and does not ask about it.
MODEL=<current model>
#
# FAST_MODE: request Codex's Fast service tier for redpen's background
# `codex exec` checks when the configured model supports it. on (default) | off.
# Unsupported models run in Standard mode.
FAST_MODE=<new fast_mode>
```

## Step 5 — Confirm

Reply with ONE short line summarising what changed. Examples:
- All changed: `✓ Switched to 中文 with native-style hints off and Fast Mode on.`
- Only language: `✓ Language set to English (hints unchanged: on, Fast Mode unchanged: on).`
- Only Fast Mode: `✓ Fast Mode off (language unchanged: English, hints unchanged: on).`
- Nothing changed: `Already on English + hints on + Fast Mode on — no change.`

New setting takes effect on your next prompt. No further explanation.
