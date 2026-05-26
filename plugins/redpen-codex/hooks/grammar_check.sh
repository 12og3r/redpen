#!/usr/bin/env bash
# UserPromptSubmit hook for Codex CLI — Codex port of redpen.
# Scores and rewrites the user's prompt in their target language via a
# synchronous headless `codex exec` call. The "[NN] <rewrite>" line is
# emitted as JSON `systemMessage` — visible to the user, NOT added to the
# model's context.
#
# Pre-LLM logic only in this commit (Task 5). The codex exec call and
# diff rendering land in Task 6.

set -u

LOG_FILE="${HOME}/.codex/redpen.log"
mkdir -p "$(dirname "$LOG_FILE")"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
log "==== hook fired (pid=$$, recursion=${REDPEN_ACTIVE:-0}) ===="

# Recursion guard: our own `codex exec` invocation (Task 6) may re-trigger
# this hook in the nested headless session. Bail out fast.
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

# Skip harness-injected envelopes — system reminders, command scaffolding,
# task-notifications, etc. These are NOT the user typing prose and shouldn't
# be coached. Same list the Claude Code hook uses; Codex appears to inherit
# the same envelope conventions per the compat shim.
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

# Handle command-style prefixes:
#   /cmd                → pure slash command, skip
#   /cmd <text>         → slash command WITH args; coach just the args
#   !cmd or !cmd <text> → shell passthrough, always skip
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
# First-run guard: if the user has never configured the plugin, skip the
# rewrite AND nudge Codex to run the `redpen-setup` skill via
# UserPromptSubmit additionalContext. Re-emitting on every prompt until the
# config exists is self-healing: as soon as setup finishes, the file appears
# and the nudge stops firing on its own.
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
      "exploring code, or invoking any other tool — you MUST invoke "
      "the redpen-setup skill (type $redpen-setup or say \"run the "
      "redpen-setup skill\") to configure language, model, and "
      "native-style hint. After setup completes, then proceed with "
      "whatever the user originally asked.\n"
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
# UserPromptSubmit hooks don't receive paste metadata, so we can't isolate
# user-typed prose from pasted code/logs. Long prompts almost always contain
# pasted material we don't want to rewrite. Override via the
# MAX_PROMPT_CHARS env var or in ~/.codex/redpen.config.
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
