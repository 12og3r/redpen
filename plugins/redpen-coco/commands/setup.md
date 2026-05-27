---
description: Configure the redpen-coco plugin (language + native-style hint). Writes ~/.coco/redpen.config.
allowed-tools: Read, Write, AskUserQuestion
---

The user invoked `/redpen-coco:setup`. Follow these steps EXACTLY. Do not
explore the codebase, do not run other commands, do not summarise.

> **Note on model:** the default model is `Kimi-K2.5`, hardcoded in the hook
> (chosen via bench as the fastest reliable option on coco's internal model
> gateway). The setup flow therefore does NOT ask about model. To override,
> edit the `MODEL=` line directly in
> `plugins/redpen-coco/hooks/grammar_check.sh` (or, if installed via
> marketplace, in the cached plugin under `~/Library/Caches/coco/plugins/`).

## Step 1 — Read current config

Read `~/.coco/redpen.config`. Parse:
- `LANGUAGE=<...>` (default: `english`)
- `SHOW_HINT=<on|off>` (default: `on`)

Remember as `CURRENT_LANGUAGE` and `CURRENT_SHOW_HINT`.

**First-run case:** if the config file does NOT exist, treat both as UNSET
— do NOT mark any option with `✓` in Step 2. The defaults above only apply
when writing the config in Step 4 if the user picks Other / blank.

## Step 2 — Ask the user (single AskUserQuestion call, two questions)

Call `AskUserQuestion` ONCE with both questions. Do NOT add manual
numbering — coco's TUI renders the picker (arrow-key selection) from the
structured options.

**Current-selection marker (both questions):** append ` ✓` as a suffix to
the option whose value matches the user's current config
(`CURRENT_LANGUAGE` / `CURRENT_SHOW_HINT`). The ✓ is purely a state marker
— independent of `(Recommended)`; both can appear together (e.g. `On
(Recommended) ✓`). When matching answers back in Step 3, ignore the
trailing ` ✓`.

**Question 1 — language**
- question: `Which language do you want the redpen-coco plugin to coach you on?`
- header: `Language`
- multiSelect: false
- options (only these four; if user picks the auto-added Other, fall back to English):
  - `English` — Practise English. Plugin rewrites English prompts.
  - `中文 (Chinese)` — Practise Chinese. Plugin rewrites Chinese prompts.
  - `Español (Spanish)` — Practise Spanish. Plugin rewrites Spanish prompts.
  - `日本語 (Japanese)` — Practise Japanese. Plugin rewrites Japanese prompts.

(AskUserQuestion auto-appends an `Other` option. If the user picks it and
types a value, IGNORE the value and treat it as `English` — this plugin
only supports the four languages above.)

**Question 2 — native style line**
- question: `Show a second "native style" line with a more idiomatic rephrasing under each rewrite?`
- header: `Native style`
- multiSelect: false
- options (ALWAYS append ` (Recommended)` to `On`, regardless of
  `CURRENT_SHOW_HINT`. The native-style line is the objectively recommended
  setting for this plugin — it's where most of the learning value lives.
  Do NOT use `(Recommended)` to indicate the current selection; it is a
  recommendation, not a state marker):
  - `On` — Show the divider + native-style rephrasing line under each rewrite.
  - `Off` — Only show the scored rewrite line. No second line.

## Step 3 — Map answers to config values

Language:
- `English` → `english`
- `中文 (Chinese)` → `chinese`
- `Español (Spanish)` → `spanish`
- `日本語 (Japanese)` → `japanese`
- `Other` (any custom value the user typed) → `english` — this plugin
  only supports the four languages above; ignore whatever string the user
  typed.

Native hint:
- `On ...` → `on`
- `Off ...` → `off`
- `Other` (anything else) → `on` (fall back to default).

## Step 4 — Write the new config

Use `Write` to overwrite `~/.coco/redpen.config` with EXACTLY this content
(substitute the chosen values):

```
# redpen-coco plugin config — sourced by the user_prompt_submit hook.
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
# NOTE: MODEL is locked to Kimi-K2.5 (the bench winner on coco's internal
# model gateway). To override, edit the MODEL= line in
# plugins/redpen-coco/hooks/grammar_check.sh directly.
```

## Step 5 — Confirm

Reply with ONE short line summarising what changed, e.g.:
- Both changed: `✓ Switched to 中文 with native-style hints off.`
- Only language: `✓ Language set to English (hints unchanged: on).`
- Only hint: `✓ Native-style hints off (language unchanged: English).`
- Nothing changed: `Already on English + hints on — no change.`

New setting takes effect on your next prompt. No further explanation.
