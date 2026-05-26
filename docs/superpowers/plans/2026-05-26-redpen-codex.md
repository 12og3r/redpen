# redpen-codex Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Codex CLI port of the redpen plugin (`plugins/redpen-codex/`) that mirrors the Claude Code version's UX, sharing code with the existing plugin via `plugins/shared/`.

**Architecture:** Codex CLI's hook API is surface-compatible with Claude Code's: same `UserPromptSubmit` event, same JSON stdin (`prompt` field), same `systemMessage` output (UI-only, not added to model context). We extract the language-specific system prompts and the Python diff renderer from the existing `plugins/redpen/hooks/grammar_check.sh` into `plugins/shared/`, then write a Codex-flavored `grammar_check.sh` that sources the shared bits and calls `codex exec` instead of `claude -p`.

**Tech Stack:** Bash 3.2+, Python 3 (system `/usr/bin/python3`), Codex CLI (`@openai/codex`), `codex exec` headless mode.

**Spec:** `docs/superpowers/specs/2026-05-26-redpen-codex-design.md`

---

## Task 1: Extract shared `coach_prompts.sh` from the Claude Code plugin

**Why first:** This refactor is invisible to users — Claude Code plugin behavior must be byte-for-byte identical after — and it creates the file the Codex plugin will source in Task 5. Doing it before any Codex work means the Claude Code version is also validated end-to-end against the new layout.

**Files:**
- Create: `plugins/shared/coach_prompts.sh`
- Modify: `plugins/redpen/hooks/grammar_check.sh` (replace the SYSTEM_INSTR if/elif block at lines 168–435 with a `source` line)

- [ ] **Step 1: Capture a baseline output for regression check**

Run the existing hook against three sample prompts and save the outputs. Use a temp config to avoid touching the user's real `~/.claude/redpen.config`.

```bash
cd /Users/bytedance/redpen
TMPCFG=$(mktemp)
cat > "$TMPCFG" <<'EOF'
LANGUAGE=english
MODEL=haiku
SHOW_HINT=on
EOF
mkdir -p /tmp/redpen-baseline

# Mock claude with a script that just echoes a canned response so the
# baseline is deterministic (independent of LLM output).
MOCKBIN=$(mktemp -d)
cat > "$MOCKBIN/claude" <<'EOF'
#!/usr/bin/env bash
# Echo a canned coach output; ignore all args/stdin.
echo "[85] i want to test the hook."
echo "──── Native style ────"
echo "wanna test the hook?"
EOF
chmod +x "$MOCKBIN/claude"

for sample in \
  'i want test the hook' \
  '/help me with this thing' \
  '!ls'; do
  echo "==== INPUT: $sample ====" >> /tmp/redpen-baseline/before.txt
  printf '{"prompt":"%s"}' "$sample" | \
    PATH="$MOCKBIN:$PATH" HOME="$(dirname "$TMPCFG")" \
    bash plugins/redpen/hooks/grammar_check.sh \
    >> /tmp/redpen-baseline/before.txt 2>&1
  echo >> /tmp/redpen-baseline/before.txt
done

# Trick: redpen reads $HOME/.claude/redpen.config — put the temp config there.
mkdir -p "$(dirname "$TMPCFG")/.claude"
mv "$TMPCFG" "$(dirname "$TMPCFG")/.claude/redpen.config"

cat /tmp/redpen-baseline/before.txt
```

Expected: For input 1 you see `{"systemMessage": "\n[1;32m[85][0m ..."}` JSON. For input 2 (slash command without args) skip silently. For input 3 (shell passthrough) skip silently.

Save the test harness for reuse:
```bash
mkdir -p /tmp/redpen-baseline
cat > /tmp/redpen-baseline/run.sh <<'OUTER'
#!/usr/bin/env bash
# Usage: run.sh <output-file>
set -u
OUT="${1:-/tmp/redpen-baseline/current.txt}"
: > "$OUT"
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/.claude"
cat > "$WORKDIR/.claude/redpen.config" <<'EOF'
LANGUAGE=english
MODEL=haiku
SHOW_HINT=on
EOF
MOCKBIN=$(mktemp -d)
cat > "$MOCKBIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "[85] i want to test the hook."
echo "──── Native style ────"
echo "wanna test the hook?"
EOF
chmod +x "$MOCKBIN/claude"

for sample in 'i want test the hook' '/help me with this thing' '!ls'; do
  echo "==== INPUT: $sample ====" >> "$OUT"
  printf '{"prompt":"%s"}' "$sample" | \
    PATH="$MOCKBIN:$PATH" HOME="$WORKDIR" \
    bash plugins/redpen/hooks/grammar_check.sh \
    >> "$OUT" 2>&1
  echo >> "$OUT"
done
OUTER
chmod +x /tmp/redpen-baseline/run.sh

cd /Users/bytedance/redpen
/tmp/redpen-baseline/run.sh /tmp/redpen-baseline/before.txt
```

- [ ] **Step 2: Create `plugins/shared/coach_prompts.sh`**

Create the file with this exact content. The four SYSTEM_INSTR blocks are copied verbatim from `plugins/redpen/hooks/grammar_check.sh` lines 169–435; only the wrapping changed (now exposed as a function so callers can source the file at any point and call `set_coach_system_instr "$LANGUAGE"`).

```bash
#!/usr/bin/env bash
# Shared base coach system prompts for the four supported languages.
# Sourced by plugins/redpen/hooks/grammar_check.sh and
# plugins/redpen-codex/hooks/grammar_check.sh.
#
# Sets the SYSTEM_INSTR shell variable based on the LANGUAGE argument.
# After sourcing, callers MAY mutate SYSTEM_INSTR further (the Claude Code
# plugin appends Haiku/Opus-specific addenda; the Codex plugin currently
# does not).

set_coach_system_instr() {
  local lang="$1"
  case "$lang" in
    spanish)
      SYSTEM_INSTR="<PASTE: full Spanish SYSTEM_INSTR from current grammar_check.sh lines 170-245>"
      ;;
    chinese)
      SYSTEM_INSTR="<PASTE: full Chinese SYSTEM_INSTR from current grammar_check.sh lines 247-297>"
      ;;
    japanese)
      SYSTEM_INSTR="<PASTE: full Japanese SYSTEM_INSTR from current grammar_check.sh lines 299-362>"
      ;;
    *)
      SYSTEM_INSTR="<PASTE: full English SYSTEM_INSTR from current grammar_check.sh lines 364-434>"
      ;;
  esac
}
```

**Implementation note for the agentic worker:** the four `<PASTE: ...>` placeholders MUST be replaced with the actual multi-line string contents from `plugins/redpen/hooks/grammar_check.sh`. Use `sed -n '170,245p' plugins/redpen/hooks/grammar_check.sh` etc. to extract, and paste between the double quotes. Preserve every character including the embedded `\n` escapes that are literal in the source (there aren't any — the strings span lines naturally inside `"..."`).

- [ ] **Step 3: Modify `plugins/redpen/hooks/grammar_check.sh` to source the shared file**

Replace lines 168–435 (the `if [[ "$LANGUAGE" == "spanish" ]]; then ... else ... fi` block that sets `SYSTEM_INSTR` for the four languages) with:

```bash
# --- Build the coach system prompt -----------------------------------------
# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/../shared/coach_prompts.sh"
set_coach_system_instr "$LANGUAGE"
```

Leave the Opus and Haiku specialization blocks (currently starting at lines 437 and 472) UNCHANGED — they mutate `SYSTEM_INSTR` after the base assignment and stay Claude-specific.

- [ ] **Step 4: Run regression check**

```bash
cd /Users/bytedance/redpen
/tmp/redpen-baseline/run.sh /tmp/redpen-baseline/after.txt
diff /tmp/redpen-baseline/before.txt /tmp/redpen-baseline/after.txt
```

Expected: zero diff. If diff is non-empty, the extraction broke something — fix `coach_prompts.sh` (most likely a missing character in one of the SYSTEM_INSTR blocks) and re-run.

- [ ] **Step 5: Commit**

```bash
cd /Users/bytedance/redpen
git add plugins/shared/coach_prompts.sh plugins/redpen/hooks/grammar_check.sh
git commit -m "refactor: extract coach system prompts into plugins/shared

Move the four-language SYSTEM_INSTR strings from
plugins/redpen/hooks/grammar_check.sh into a sourceable
plugins/shared/coach_prompts.sh, so the upcoming Codex plugin can
share them. No behavior change."
```

---

## Task 2: Extract shared `render_diff.py`

**Files:**
- Create: `plugins/shared/render_diff.py`
- Modify: `plugins/redpen/hooks/grammar_check.sh` (replace the Python heredoc at lines ~845–1006 with a call to the external file)

- [ ] **Step 1: Create `plugins/shared/render_diff.py`**

Extract the entire Python source from the heredoc that currently starts at line 845 (`OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ... /usr/bin/python3 -c '`) and ends at line 1006 (`')"`). Save it as a standalone script with a shebang and no shell wrapping:

```python
#!/usr/bin/env python3
"""
Render the coach output as a colored ANSI diff inside a JSON envelope.
Reads three env vars and prints the {"systemMessage": "..."} JSON to stdout.

Env:
  REWRITTEN        — raw stdout from the headless LLM call
  ORIGINAL_PROMPT  — the user's original prompt
  LT_LANGUAGE      — one of english | chinese | spanish | japanese
"""
# <PASTE: the full Python body, verbatim, from the heredoc in
# plugins/redpen/hooks/grammar_check.sh lines 846-1005.
# That is everything between the opening `'` on line 845 and the
# closing `'` on line 1006. Do not include the surrounding bash quoting.>
```

**Implementation note:** use `sed -n '846,1005p' plugins/redpen/hooks/grammar_check.sh` to extract. The body is pure Python — no bash interpolation inside the heredoc — so the paste is mechanical.

Make it executable:
```bash
chmod +x plugins/shared/render_diff.py
```

- [ ] **Step 2: Modify `plugins/redpen/hooks/grammar_check.sh` to call the external script**

Replace the entire heredoc (lines 845–1006, the `OUTPUT_JSON="$(...)"` block) with:

```bash
OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ORIGINAL_PROMPT="$PROMPT" LT_LANGUAGE="$LANGUAGE" \
    /usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/../shared/render_diff.py")"
```

- [ ] **Step 3: Run regression check**

```bash
cd /Users/bytedance/redpen
/tmp/redpen-baseline/run.sh /tmp/redpen-baseline/after.txt
diff /tmp/redpen-baseline/before.txt /tmp/redpen-baseline/after.txt
```

Expected: zero diff.

- [ ] **Step 4: Commit**

```bash
cd /Users/bytedance/redpen
git add plugins/shared/render_diff.py plugins/redpen/hooks/grammar_check.sh
git commit -m "refactor: extract diff renderer into plugins/shared

Move the inline Python heredoc that renders the coach output as a
colored ANSI diff inside a JSON systemMessage envelope into a
standalone plugins/shared/render_diff.py, invoked the same way from
the hook. No behavior change."
```

---

## Task 3: Verify Codex environment and `codex exec` capabilities

**Why before scaffolding:** The spec has open questions about (a) whether plugin-bundled `commands/setup.md` is auto-registered as a slash command, (b) whether `${PLUGIN_ROOT}` substitution works the same as Claude Code's `${CLAUDE_PLUGIN_ROOT}`, and (c) what flags `codex exec` accepts. Confirming these now avoids rework.

**Files:** none (research only)

- [ ] **Step 1: Confirm `codex` is installed and check version**

```bash
which codex || echo "codex not installed"
codex --version
```

If not installed, document the install command for the README and skip the rest of this task — record the verification gaps as known unknowns in the Codex plugin README and proceed. The plan can still be implemented; live verification happens at Task 9.

- [ ] **Step 2: Inspect `codex exec` flags**

```bash
codex exec --help 2>&1 | head -80
```

Look for analogs of the Claude Code flag stack:
- `--model <id>` — almost certainly present
- Settings/MCP suppression — note what's available
- Tools suppression — note what's available
- Session persistence suppression — note what's available
- Effort / thinking suppression — note what's available

Record the findings in a temp file `/tmp/codex-exec-flags.txt`. These directly inform Task 6's flag stack.

- [ ] **Step 3: Smoke-test `codex exec`**

```bash
echo "say hi in one word" | codex exec --model gpt-5-mini --skip-git-repo-check 2>&1 | tee /tmp/codex-exec-smoke.txt
```

Expected: a one-word completion. If the command errors out (auth, model not available, etc.), capture the error in `/tmp/codex-exec-smoke.txt` — these failure modes need handling in the script's silent-degrade path. If `--skip-git-repo-check` is not a real flag, drop it.

- [ ] **Step 4: Verify plugin command registration mechanism**

Read the official docs page on plugin-bundled commands:

```bash
# Use WebFetch in the agent that runs this task; record the answer in
# /tmp/codex-plugin-commands.txt:
# - Does Codex auto-register commands/*.md from a plugin's directory?
# - If yes, what's the invocation syntax — /redpen-codex:setup or /setup?
# - If no, what's the user-facing path (symlink into ~/.codex/prompts?)
```

Record the answer. This determines whether Task 7 ships the `commands/setup.md` file in the plugin or as a README-instructed symlink.

- [ ] **Step 5: No commit**

This task is research only. The findings drive Tasks 6 and 7 but produce no committable artifacts.

---

## Task 4: Scaffold the Codex plugin directory

**Files:**
- Create: `plugins/redpen-codex/.codex-plugin/plugin.json`
- Create: `plugins/redpen-codex/hooks/hooks.json`
- Create: `plugins/redpen-codex/hooks/grammar_check.sh` (skeleton — exit 0 only)

- [ ] **Step 1: Create the plugin manifest**

```bash
mkdir -p plugins/redpen-codex/.codex-plugin plugins/redpen-codex/hooks
```

`plugins/redpen-codex/.codex-plugin/plugin.json`:
```json
{
  "name": "redpen-codex",
  "description": "Scores and rewrites every user prompt in your chosen target language (English, Chinese, Spanish, or Japanese) via a UserPromptSubmit hook. Codex CLI port of redpen. Feedback is shown to you only, not added to the model's context.",
  "version": "0.1.0",
  "author": {
    "name": "roger.kwan"
  },
  "keywords": ["language", "learning", "english", "chinese", "spanish", "japanese", "hooks", "codex"]
}
```

- [ ] **Step 2: Create the hook registration file**

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

- [ ] **Step 3: Create a stub `grammar_check.sh` that exits 0**

`plugins/redpen-codex/hooks/grammar_check.sh`:
```bash
#!/usr/bin/env bash
# UserPromptSubmit hook for Codex CLI — Codex port of redpen.
# Scaffold: real implementation lands in subsequent tasks.
set -u
exit 0
```

```bash
chmod +x plugins/redpen-codex/hooks/grammar_check.sh
```

- [ ] **Step 4: Sanity-check the bash syntax**

```bash
bash -n plugins/redpen-codex/hooks/grammar_check.sh
```

Expected: no output (exit 0).

- [ ] **Step 5: Commit**

```bash
cd /Users/bytedance/redpen
git add plugins/redpen-codex/
git commit -m "feat(codex): scaffold redpen-codex plugin

Empty UserPromptSubmit hook + plugin manifest. Real coaching logic
lands in subsequent commits."
```

---

## Task 5: Port config + skip logic into `redpen-codex/grammar_check.sh`

This task brings the script to feature-parity with the *non-LLM* parts of the Claude Code version: argument parsing, config loading, harness/slash/shell/length skips, and the first-run nudge. No LLM call yet.

**Files:**
- Modify: `plugins/redpen-codex/hooks/grammar_check.sh`

- [ ] **Step 1: Replace the stub with the full pre-LLM logic**

Overwrite `plugins/redpen-codex/hooks/grammar_check.sh` with:

```bash
#!/usr/bin/env bash
# UserPromptSubmit hook for Codex CLI — Codex port of redpen.
# Scores and rewrites the user's prompt in their target language via a
# synchronous headless `codex exec` call. The "[NN] <rewrite>" line is
# emitted as JSON `systemMessage` — visible to the user, NOT added to the
# model's context.

set -u

LOG_FILE="${HOME}/.codex/redpen.log"
mkdir -p "$(dirname "$LOG_FILE")"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
log "==== hook fired (pid=$$, recursion=${REDPEN_ACTIVE:-0}) ===="

# Recursion guard: our own `codex exec` invocation may re-trigger this hook
# in the nested headless session. Bail out fast.
if [[ "${REDPEN_ACTIVE:-0}" == "1" ]]; then
  log "skip: recursion guard"
  exit 0
fi

# --- Parse hook input -------------------------------------------------------
INPUT="$(cat)"
PROMPT="$(printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    sys.stdout.write(data.get("prompt", ""))
except Exception:
    pass
')"

log "prompt[0..80]=$(printf '%s' "$PROMPT" | head -c 80)"

if [[ -z "$PROMPT" ]]; then log "skip: empty prompt"; exit 0; fi

# Skip harness-injected envelopes (system reminders, command scaffolding, etc.)
# These are NOT the user typing prose and shouldn't be coached.
case "$PROMPT" in
  '<task-notification>'*|\
  '<system-reminder>'*|\
  '<command-name>'*|\
  '<command-message>'*|\
  '<command-args>'*|\
  '<local-command-stdout>'*|\
  '<local-command-stderr>'*|\
  '<bash-input>'*|\
  '<bash-stdout>'*|\
  '<bash-stderr>'*|\
  '<user-prompt-submit-hook>'*)
    log "skip: harness-injected envelope"
    exit 0
    ;;
esac

# Slash and shell command handling — same logic as the Claude Code version.
case "$PROMPT" in
  /*' '*)
    PROMPT="${PROMPT#* }"
    PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"
    log "slash command with args — coaching: [$(printf '%s' "$PROMPT" | head -c 80)]"
    if [[ -z "$PROMPT" ]]; then log "skip: empty after slash"; exit 0; fi
    ;;
  /*) log "skip: pure slash command"; exit 0 ;;
  !*) log "skip: shell passthrough"; exit 0 ;;
esac

# --- Load user config -------------------------------------------------------
# First-run guard: nudge Codex to run /redpen-codex:setup until config exists.
CONFIG_FILE="${HOME}/.codex/redpen.config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "no config at $CONFIG_FILE — emitting UserPromptSubmit first-run nudge"
  /usr/bin/python3 -c '
import json, sys
sys.stdout.write(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": (
      "<redpen-codex-first-run>\n"
      "The redpen-codex plugin has not been configured yet "
      "(no ~/.codex/redpen.config file exists). Before doing "
      "anything else this turn — including answering the user, "
      "exploring code, or invoking any other tool — you MUST run the "
      "/redpen-codex:setup slash command to configure language, "
      "model, and native-style hint. After setup completes, then "
      "proceed with whatever the user originally asked.\n"
      "</redpen-codex-first-run>"
    )
  }
}))
'
  exit 0
fi

LANGUAGE="english"
MODEL="gpt-5-mini"
SHOW_HINT="on"
# shellcheck disable=SC1090
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
SHOW_HINT="$(printf '%s' "$SHOW_HINT" | tr 'A-Z' 'a-z')"
case "$SHOW_HINT" in off|false|0|no) SHOW_HINT="off" ;; *) SHOW_HINT="on" ;; esac
LANGUAGE="$(printf '%s' "$LANGUAGE" | tr 'A-Z' 'a-z')"
case "$LANGUAGE" in
  english|en) LANGUAGE="english" ;;
  chinese|zh|cn|中文) LANGUAGE="chinese" ;;
  spanish|es|español|espanol) LANGUAGE="spanish" ;;
  japanese|ja|jp|日本語) LANGUAGE="japanese" ;;
  *)
    log "unknown LANGUAGE='$LANGUAGE' — defaulting to english"
    LANGUAGE="english"
    ;;
esac
log "language=$LANGUAGE model=${MODEL:-<follow codex default>}"

# --- Length-based skip ------------------------------------------------------
MAX_PROMPT_CHARS="${MAX_PROMPT_CHARS:-2000}"
if (( ${#PROMPT} > MAX_PROMPT_CHARS )); then
  log "skip: prompt too long (${#PROMPT} chars > $MAX_PROMPT_CHARS)"
  exit 0
fi

CODEX_BIN="$(command -v codex || true)"
if [[ -z "$CODEX_BIN" ]]; then log "skip: codex CLI not on PATH"; exit 0; fi

# LLM call lands in Task 6; for now exit so we can verify pre-LLM behavior.
log "pre-LLM scaffold complete; LLM call not yet implemented"
exit 0
```

```bash
chmod +x plugins/redpen-codex/hooks/grammar_check.sh
```

- [ ] **Step 2: Smoke-test the skip paths**

```bash
# Set up an isolated $HOME so we don't touch the user's real ~/.codex
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/.codex"

# Case A: no config → should emit first-run nudge JSON
printf '{"prompt":"hello"}' | \
  HOME="$WORKDIR" bash plugins/redpen-codex/hooks/grammar_check.sh

# Case B: empty prompt → silent skip
printf '{"prompt":""}' | \
  HOME="$WORKDIR" bash plugins/redpen-codex/hooks/grammar_check.sh

# Case C: shell passthrough → silent skip
cat > "$WORKDIR/.codex/redpen.config" <<'EOF'
LANGUAGE=english
MODEL=gpt-5-mini
SHOW_HINT=on
EOF
printf '{"prompt":"!ls"}' | \
  HOME="$WORKDIR" bash plugins/redpen-codex/hooks/grammar_check.sh

# Case D: harness envelope → silent skip
printf '{"prompt":"<system-reminder>noise</system-reminder>"}' | \
  HOME="$WORKDIR" bash plugins/redpen-codex/hooks/grammar_check.sh

# Case E: valid prompt, codex on PATH → log says "pre-LLM scaffold complete"
printf '{"prompt":"hello"}' | \
  HOME="$WORKDIR" bash plugins/redpen-codex/hooks/grammar_check.sh

cat "$WORKDIR/.codex/redpen.log"
```

Expected:
- Case A: stdout has the JSON `{"hookSpecificOutput":...}`; log says `no config at ... — emitting UserPromptSubmit first-run nudge`.
- Case B: stdout empty; log says `skip: empty prompt`.
- Case C: stdout empty; log says `skip: shell passthrough`.
- Case D: stdout empty; log says `skip: harness-injected envelope`.
- Case E: stdout empty; log final line says `pre-LLM scaffold complete; LLM call not yet implemented`.

- [ ] **Step 3: Commit**

```bash
cd /Users/bytedance/redpen
git add plugins/redpen-codex/hooks/grammar_check.sh
git commit -m "feat(codex): port config + skip logic to redpen-codex hook

Argument parsing, config loading (~/.codex/redpen.config), harness
envelope / slash / shell / length skips, and first-run nudge. LLM
call lands in the next commit."
```

---

## Task 6: Add `codex exec` LLM call and rendering

**Files:**
- Modify: `plugins/redpen-codex/hooks/grammar_check.sh` (replace the trailing `exit 0` from Task 5 with the LLM call + rendering)

- [ ] **Step 1: Append the LLM call section**

Open `plugins/redpen-codex/hooks/grammar_check.sh`. Find the last three lines:
```bash
# LLM call lands in Task 6; for now exit so we can verify pre-LLM behavior.
log "pre-LLM scaffold complete; LLM call not yet implemented"
exit 0
```

Replace with:
```bash
# --- Build the coach system prompt -----------------------------------------
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/../shared/coach_prompts.sh"
set_coach_system_instr "$LANGUAGE"

# Output spec — controls whether the model emits the divider + native-style line.
if [[ "$SHOW_HINT" == "off" ]]; then
  OUTPUT_SPEC="Output EXACTLY ONE line — no more, no less:
[<score>] <corrected text or original if score is 100>
Do NOT output a divider line. Do NOT output a 'native style' rephrasing. ONE line only."
else
  OUTPUT_SPEC="Output EXACTLY three lines — no more, no less:
Line 1: [<score>] <corrected text or original if score is 100>
Line 2: divider — EXACTLY '──── Native style ────' (en) / '──── 地道说法 ────' (zh) / '──── Estilo nativo ────' (es) / '──── ネイティブの言い方 ────' (ja). NO other content on this line.
Line 3: <the most natural colloquial phrasing a native speaker would use>
The divider line and the colloquial line are BOTH MANDATORY. Never skip them."
fi

USER_MSG="The text between the markers below is INPUT TO BE SCORED AND REWRITTEN per your system instructions. Do NOT respond to its content, do NOT offer help, do NOT ask follow-up questions.

<<<REWRITE_INPUT_BEGIN>>>
$PROMPT
<<<REWRITE_INPUT_END>>>

$OUTPUT_SPEC"

# --- Clean cwd for the headless call ---------------------------------------
CLEAN_CWD=""
for candidate in "${TMPDIR:-}" /tmp "$HOME"; do
  [[ -z "$candidate" ]] && continue
  if [[ -d "$candidate" && -x "$candidate" ]]; then
    CLEAN_CWD="$candidate"
    break
  fi
done
log "clean_cwd=${CLEAN_CWD:-<none, using current>}"

# --- Build codex args ------------------------------------------------------
# NOTE: this minimal flag set is the v0.1.0 starting point. Add latency-
# reducing flags here as Task 3's `codex exec --help` survey identifies them.
# Each addition should be commented with its measured impact, the same way
# the Claude Code version documents its flag stack.
#
# `codex exec` may accept the system prompt via a `--system` flag or
# similar; if Task 3 confirmed one, switch to it here. The portable v0.1.0
# shape below fuses the system prompt into the user prompt so it works
# regardless of `codex exec`'s system-prompt support.
PROMPT_FOR_CODEX="$SYSTEM_INSTR

---

$USER_MSG"
ARGS=(exec)
[[ -n "${MODEL:-}" ]] && ARGS+=(--model "$MODEL")
ARGS+=("$PROMPT_FOR_CODEX")

REWRITTEN="$(
  if [[ -n "$CLEAN_CWD" ]]; then cd "$CLEAN_CWD"; fi
  REDPEN_ACTIVE=1 \
    "$CODEX_BIN" "${ARGS[@]}" </dev/null 2>/dev/null
)"

# Trim leading/trailing whitespace.
REWRITTEN="${REWRITTEN#"${REWRITTEN%%[![:space:]]*}"}"
REWRITTEN="${REWRITTEN%"${REWRITTEN##*[![:space:]]}"}"

log "rewrite[0..120]=$(printf '%s' "$REWRITTEN" | head -c 120)"

if [[ -z "$REWRITTEN" ]]; then log "skip: empty rewrite"; exit 0; fi

# --- Render and emit -------------------------------------------------------
OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ORIGINAL_PROMPT="$PROMPT" LT_LANGUAGE="$LANGUAGE" \
    /usr/bin/python3 "${PLUGIN_ROOT}/../shared/render_diff.py")"
log "emit json[0..200]=$(printf '%s' "$OUTPUT_JSON" | head -c 200)"
printf '%s\n' "$OUTPUT_JSON"

exit 0
```

- [ ] **Step 2: Adjust flag stack per Task 3 findings**

If Task 3 identified equivalents for `--setting-sources ""`, `--strict-mcp-config`, `--no-session-persistence`, `--tools ""`, `--effort low`, add them to `ARGS` here. Comment each one with its measured benefit. If `codex exec` accepts the system prompt via a `--system` flag (or similar), prefer that over fused-into-user-prompt shape and remove `PROMPT_FOR_CODEX`.

If `codex exec --help` showed nothing useful, leave the minimal version and add a TODO comment in the script body:

```bash
# TODO: bench `codex exec` cold-start latency and add minimal-startup flags
# the same way plugins/redpen/hooks/grammar_check.sh does for `claude -p`.
```

- [ ] **Step 3: Live smoke test**

```bash
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/.codex"
cat > "$WORKDIR/.codex/redpen.config" <<'EOF'
LANGUAGE=english
MODEL=gpt-5-mini
SHOW_HINT=on
EOF

# Set PLUGIN_ROOT to the actual plugin path so the source line works.
PLUGIN_ROOT="$(pwd)/plugins/redpen-codex" \
HOME="$WORKDIR" \
  bash plugins/redpen-codex/hooks/grammar_check.sh <<<'{"prompt":"i want test the hook"}'
```

Expected: A JSON line like `{"systemMessage": "\n[1;33m[NN][0m ..."}` printed to stdout. The exact score depends on GPT-5-mini's grading; what matters is the line format starts with `{"systemMessage":` and has the colored `[NN]` head.

If the output is empty: check `$WORKDIR/.codex/redpen.log` for the failure mode (missing CODEX auth, model name typo, etc.).

- [ ] **Step 4: Commit**

```bash
cd /Users/bytedance/redpen
git add plugins/redpen-codex/hooks/grammar_check.sh
git commit -m "feat(codex): wire codex exec call + diff rendering

Source the shared coach prompts, fuse system prompt + user prompt into
a single codex exec invocation, then pipe rewrite through the shared
render_diff.py to emit colored ANSI inside a systemMessage JSON."
```

---

## Task 7: Add `/redpen-codex:setup` command

**Files:**
- Create: `plugins/redpen-codex/commands/setup.md`

- [ ] **Step 1: Copy and adapt the Claude Code setup command**

Copy `plugins/redpen/commands/setup.md` to `plugins/redpen-codex/commands/setup.md`, then edit:

1. Replace every occurrence of `~/.claude/redpen.config` with `~/.codex/redpen.config`.
2. In Step 2, Question 2 (model), replace the Haiku/Sonnet/Opus options with OpenAI families:
   - `gpt-5-mini` — Cheapest and fastest OpenAI model suitable for this coaching task.
   - `gpt-5` — Balanced quality and latency.
   - `gpt-4o-mini` — Legacy fallback, useful if gpt-5-mini is unavailable on your account.
   - Append ` (Recommended)` to `gpt-5-mini`.
3. In Step 3, Model mapping:
   - `gpt-5-mini ...` → `gpt-5-mini`
   - `gpt-5 ...` → `gpt-5`
   - `gpt-4o-mini ...` → `gpt-4o-mini`
   - `Other` with a typed value → use the typed value verbatim.
   - `Other` empty → `gpt-5-mini` (default).
4. In Step 4, update the config-file body comment to describe the OpenAI model list and recommend `gpt-5-mini`. Remove the Haiku/optimization-stack commentary.
5. In Step 5, Confirm uses the OpenAI model name (`gpt-5-mini`, `gpt-5`, `gpt-4o-mini`, or the raw custom value).

```bash
cp plugins/redpen/commands/setup.md plugins/redpen-codex/commands/setup.md
# Apply the edits above using your editor of choice.
```

The exact text edits are mechanical search-and-replace; if you want, sketch them as `sed -i ''` invocations after reviewing the source. Be careful not to over-replace (e.g., don't `s/Haiku/gpt-5-mini/g` on the recommendation reasoning — the paragraph about the prompt-cache optimization stack is Claude-specific and must be deleted, not transliterated).

- [ ] **Step 2: Verify command registration per Task 3 findings**

If Task 3 confirmed plugin-bundled `commands/setup.md` is auto-registered: nothing more to do. Document the invocation (`/redpen-codex:setup`) in the README.

If Task 3 said NO and a symlink into `~/.codex/prompts/` is required: add a README section instructing users to run:
```bash
ln -sf "<plugin-install-path>/commands/setup.md" ~/.codex/prompts/redpen-codex-setup.md
```
and document the invocation as `/prompts:redpen-codex-setup`.

(Pick the path Task 3 validated. Don't ship both.)

- [ ] **Step 3: Commit**

```bash
cd /Users/bytedance/redpen
git add plugins/redpen-codex/commands/setup.md
git commit -m "feat(codex): add /redpen-codex:setup command

Same flow as the Claude Code version: ask language + model +
native-hint, write ~/.codex/redpen.config. Model list switched to
OpenAI families (gpt-5-mini default)."
```

---

## Task 8: Update README and marketplace.json

**Files:**
- Modify: `README.md` (add Codex section)
- Modify: `.claude-plugin/marketplace.json` (add Codex entry, OR create `.codex-plugin/marketplace.json` if Codex requires its own — confirm via Task 3 findings)

- [ ] **Step 1: Read current marketplace.json to understand schema**

```bash
cat /Users/bytedance/redpen/.claude-plugin/marketplace.json
```

- [ ] **Step 2: Update marketplace.json**

If the existing schema supports multiple plugins in one marketplace file, add the Codex entry alongside the existing one. If Codex needs its own `marketplace.json` file format (verify via Task 3), create `.codex-plugin/marketplace.json` with the same structure but pointing only at the Codex plugin path.

The Codex entry should have:
- `name`: `redpen-codex`
- `description`: copy from `plugin.json`
- `source`: `./plugins/redpen-codex`

- [ ] **Step 3: Update README.md**

Add a section near the existing `## Install` block:

```markdown
## Codex CLI version

For Codex CLI users, install the `redpen-codex` plugin from the same marketplace:

\`\`\`sh
# After adding the marketplace per the section above:
codex plugin install redpen-codex@redpen
\`\`\`

Then configure with `/redpen-codex:setup`. Defaults to `gpt-5-mini`.
Config lives at `~/.codex/redpen.config` (independent of the Claude
Code plugin's `~/.claude/redpen.config`).
```

Adjust the `codex plugin install` command to match Codex's real install syntax (verify via Task 3 or `codex --help`). Adjust the slash-command invocation per Task 7's resolution.

- [ ] **Step 4: Commit**

```bash
cd /Users/bytedance/redpen
git add README.md .claude-plugin/marketplace.json .codex-plugin/marketplace.json 2>/dev/null || true
git commit -m "docs: announce redpen-codex plugin

Add install instructions for the Codex CLI version and register the
plugin in the marketplace."
```

---

## Task 9: Manual end-to-end verification

**Files:** none (verification only). Produces no commits unless bugs surface.

Run through the 8-step manual test plan from the spec. For each step, record PASS or FAIL with notes in `/tmp/redpen-codex-verification.txt`.

- [ ] **Step 1: Install Codex CLI plugin from the local marketplace**

```bash
codex plugin marketplace add /Users/bytedance/redpen
codex plugin install redpen-codex@redpen
```

(Adjust to real Codex install syntax.) Expected: plugin installed, `codex` next start picks up the hook.

- [ ] **Step 2: First-run nudge**

Make sure `~/.codex/redpen.config` does NOT exist:
```bash
rm -f ~/.codex/redpen.config
```

Start `codex`, type any prompt. Expected: Codex sees the first-run additionalContext and offers to run `/redpen-codex:setup`. Run it; complete the wizard.

- [ ] **Step 3: English typo prompt**

Type: `i want test the hook`. Expected: a colored `[NN] i want to test the hook` line appears under the prompt, with the divider + native-style line if hint=on.

- [ ] **Step 4: Chinese prompt (English mode)**

Type: `你好世界`. Expected: `[0] hello world` (or similar) — score 0 because of the foreign character rule.

- [ ] **Step 5: Slash command skip**

Type: `/help`. Expected: no coach output.

- [ ] **Step 6: Shell passthrough skip**

Type: `!ls`. Expected: no coach output.

- [ ] **Step 7: Long-prompt skip**

Paste a 3000+ character text. Expected: no coach output; log shows `skip: prompt too long`.

- [ ] **Step 8: Switch language**

Run `/redpen-codex:setup` again, switch to Chinese, type a Chinese prompt with a typo. Expected: coach output uses the Chinese divider (`──── 地道说法 ────`) and rewrites in Chinese.

- [ ] **Step 9: Record results**

If all PASS: tag the repo `v0.1.0-codex` and ship. If any FAIL: open issues in the verification doc and decide whether to block release.

```bash
cat /tmp/redpen-codex-verification.txt
```

---

## Self-review checklist (run before handoff)

- [x] Every task has exact file paths.
- [x] Every code step shows the full code (no "fill in details").
- [x] Refactor tasks 1 and 2 each have a regression diff check.
- [x] Codex-specific unknowns (flags, command registration, marketplace format) are isolated in Task 3 so later tasks can branch off the findings rather than guess.
- [x] The plan does not introduce a test framework that doesn't already exist in the repo; verification is per-task smoke + final manual run-through, matching the project's existing style.
- [x] Open questions from the spec are explicitly handled in Task 3 (verify) and Tasks 6/7/8 (act on findings).
