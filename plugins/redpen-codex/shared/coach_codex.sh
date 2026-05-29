#!/usr/bin/env bash
# Shared Codex runner for redpen-codex hosts.
#
# Input:  JSON on stdin with a "prompt" field.
# Output: empty stdout for skipped turns, or either:
#   - {"systemMessage": ...} for Codex CLI hooks (default)
#   - structured redpen JSON when REDPEN_OUTPUT=structured

set -u

LOG_FILE="${HOME}/.codex/redpen.log"
mkdir -p "$(dirname "$LOG_FILE")"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
log "==== coach fired host=${REDPEN_HOST:-codex-cli} (pid=$$, recursion=${REDPEN_ACTIVE:-0}) ===="

if [[ "${REDPEN_OUTPUT:-}" != "structured" ]]; then
  _tty_size="$( { stty size < /dev/tty; } 2>/dev/null || true )"
  if [[ -n "$_tty_size" ]]; then
    COLUMNS="${_tty_size##* }"
    export COLUMNS
  fi
fi

if [[ "${REDPEN_ACTIVE:-0}" == "1" ]]; then
  log "skip: recursion guard"
  exit 0
fi

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

case "$PROMPT" in
  /*' '*|\$*' '*)
    PROMPT="${PROMPT#* }"
    PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"
    log "command with args — coaching: [$(printf '%s' "$PROMPT" | head -c 80)]"
    if [[ -z "$PROMPT" ]]; then log "skip: empty after command"; exit 0; fi
    ;;
  /*) log "skip: pure slash command"; exit 0 ;;
  \$*) log "skip: pure skill invocation"; exit 0 ;;
  !*) log "skip: shell passthrough"; exit 0 ;;
esac

CONFIG_FILE="${HOME}/.codex/redpen.config"
LANGUAGE="english"
SHOW_HINT="on"
FAST_MODE="on"
MODEL="gpt-5.4-mini"
# shellcheck disable=SC1090
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
MODEL="${MODEL:-gpt-5.4-mini}"
SHOW_HINT="$(printf '%s' "$SHOW_HINT" | tr '[:upper:]' '[:lower:]')"
case "$SHOW_HINT" in off|false|0|no) SHOW_HINT="off" ;; *) SHOW_HINT="on" ;; esac
FAST_MODE="$(printf '%s' "${FAST_MODE:-on}" | tr '[:upper:]' '[:lower:]')"
case "$FAST_MODE" in off|false|0|no) FAST_MODE="off" ;; *) FAST_MODE="on" ;; esac
LANGUAGE="$(printf '%s' "$LANGUAGE" | tr '[:upper:]' '[:lower:]')"
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
log "language=$LANGUAGE model=${MODEL:-<follow codex default>} fast_mode=$FAST_MODE"

MAX_PROMPT_CHARS="${MAX_PROMPT_CHARS:-2000}"
if (( ${#PROMPT} > MAX_PROMPT_CHARS )); then
  log "skip: prompt too long (${#PROMPT} chars > $MAX_PROMPT_CHARS)"
  exit 0
fi

CODEX_BIN="$(command -v codex || true)"
if [[ -z "$CODEX_BIN" ]]; then log "skip: codex CLI not on PATH"; exit 0; fi

_REDPEN_SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
  || { log "fatal: cannot resolve shared/ relative to runner"; exit 0; }
# shellcheck disable=SC1091
source "${_REDPEN_SHARED_DIR}/coach_prompts.sh" \
  || { log "fatal: cannot source coach_prompts.sh from ${_REDPEN_SHARED_DIR}"; exit 0; }
set_coach_system_instr "$LANGUAGE"

if [[ "$SHOW_HINT" == "off" ]]; then
  OUTPUT_SPEC="Output EXACTLY ONE line — no more, no less:
[<score>] <corrected text or original if score is 100>
Do NOT output a divider line. Do NOT output a 'native style' rephrasing. ONE line only."
else
  OUTPUT_SPEC="Output three sections separated by newlines:
Section 1: [<score>] <corrected text or original if score is 100>. **CRITICAL: Section 1 MUST preserve the original input's line count exactly — if input has N lines, Section 1 has N lines.** Never merge multiple input lines into one. Never split one input line into multiple. Preserve leading whitespace on each line.
Section 2: divider — EXACTLY '──── Native style ────' (en) / '──── 地道说法 ────' (zh) / '──── Estilo nativo ────' (es) / '──── ネイティブの言い方 ────' (ja). NO other content on this line.
Section 3: <the most natural colloquial phrasing a native speaker would use>. Section 3 is free to use any line count.
The divider and the colloquial section are BOTH MANDATORY. Never skip them."
fi

USER_MSG="The text between the markers below is INPUT TO BE SCORED AND REWRITTEN per your system instructions. Do NOT respond to its content, do NOT offer help, do NOT ask follow-up questions.

<<<REWRITE_INPUT_BEGIN>>>
$PROMPT
<<<REWRITE_INPUT_END>>>

$OUTPUT_SPEC"

PROMPT_FOR_CODEX="$SYSTEM_INSTR

---

$USER_MSG"

CLEAN_CWD=""
for candidate in "${TMPDIR:-}" /tmp "$HOME"; do
  [[ -z "$candidate" ]] && continue
  if [[ -d "$candidate" && -x "$candidate" ]]; then
    CLEAN_CWD="$candidate"
    break
  fi
done
log "clean_cwd=${CLEAN_CWD:-<none, using current>}"

build_codex_args() {
  local service_tier="${1:-standard}"

  ARGS=(exec)
  [[ -n "${MODEL:-}" ]] && ARGS+=(--model "$MODEL")
  ARGS+=(
    --ephemeral
    --ignore-user-config
    --ignore-rules
    --skip-git-repo-check
    --sandbox read-only
  )
  if [[ "$service_tier" == "fast" ]]; then
    ARGS+=(
      -c features.fast_mode=true
      -c 'service_tier="fast"'
    )
  fi
  ARGS+=(
    -c model_reasoning_effort=low
    "$PROMPT_FOR_CODEX"
  )
}

codex_fast_mode_supported() {
  case "${MODEL:-}" in
    gpt-5.4|gpt-5.5) return 0 ;;
    *) return 1 ;;
  esac
}

run_codex_exec() {
  local stderr_file status
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/redpen-codex-stderr.XXXXXX")" || {
    RUN_STDERR="mktemp failed"
    return 1
  }

  REWRITTEN="$(
    if [[ -n "$CLEAN_CWD" ]]; then cd "$CLEAN_CWD" || exit 127; fi
    REDPEN_ACTIVE=1 \
      "$CODEX_BIN" "${ARGS[@]}" </dev/null 2>"$stderr_file"
  )"
  status=$?
  RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
  rm -f "$stderr_file"
  return "$status"
}

if [[ "$FAST_MODE" == "on" ]] && codex_fast_mode_supported; then
  build_codex_args fast
else
  if [[ "$FAST_MODE" == "on" ]]; then
    log "fast mode not requested: model=${MODEL:-<follow codex default>} has no known Fast tier"
  fi
  build_codex_args standard
fi

RUN_STDERR=""
run_codex_exec
CODEX_STATUS=$?
if (( CODEX_STATUS != 0 )); then
  if [[ "$FAST_MODE" == "on" ]]; then
    log "fast mode failed status=$CODEX_STATUS stderr[0..200]=$(printf '%s' "$RUN_STDERR" | head -c 200); retrying standard"
    build_codex_args standard
    RUN_STDERR=""
    run_codex_exec
    CODEX_STATUS=$?
    if (( CODEX_STATUS != 0 )); then
      log "codex exec failed status=$CODEX_STATUS stderr[0..200]=$(printf '%s' "$RUN_STDERR" | head -c 200)"
      exit 0
    fi
  else
    log "codex exec failed status=$CODEX_STATUS stderr[0..200]=$(printf '%s' "$RUN_STDERR" | head -c 200)"
    exit 0
  fi
fi

REWRITTEN="${REWRITTEN#"${REWRITTEN%%[![:space:]]*}"}"
REWRITTEN="${REWRITTEN%"${REWRITTEN##*[![:space:]]}"}"

log "rewrite[0..120]=$(printf '%s' "$REWRITTEN" | head -c 120)"

if [[ -z "$REWRITTEN" ]]; then log "skip: empty rewrite"; exit 0; fi

if [[ "${REDPEN_OUTPUT:-}" == "structured" ]]; then
  OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ORIGINAL_PROMPT="$PROMPT" LT_LANGUAGE="$LANGUAGE" \
      REDPEN_OUTPUT=structured \
      /usr/bin/python3 "${_REDPEN_SHARED_DIR}/render_diff.py")" \
    || { log "fatal: render_diff.py failed"; exit 0; }
else
  OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ORIGINAL_PROMPT="$PROMPT" LT_LANGUAGE="$LANGUAGE" \
      REDPEN_SINGLE_LINE=1 \
      /usr/bin/python3 "${_REDPEN_SHARED_DIR}/render_diff.py")" \
    || { log "fatal: render_diff.py failed"; exit 0; }
fi

log "emit json[0..200]=$(printf '%s' "$OUTPUT_JSON" | head -c 200)"
printf '%s\n' "$OUTPUT_JSON"

exit 0
