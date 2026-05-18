#!/usr/bin/env bash
# SessionStart hook: warm Node's V8 compile cache and the claude CLI bundle
# so the first UserPromptSubmit doesn't pay full cold-start cost.
#
# Pays ~$0.0001 for one no-op Haiku call. All subsequent grammar_check.sh
# invocations in this session — and future sessions, until claude is upgraded —
# read precompiled bytecode from ~/.cache/language-tutor/v8 instead of
# re-parsing the bundle.

set -u

LOG_FILE="${HOME}/.claude/language-tutor.log"
mkdir -p "$(dirname "$LOG_FILE")"
log() { printf '[%s] prewarm: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

CACHE_DIR="${HOME}/.cache/language-tutor/v8"
VERSION_FILE="${HOME}/.cache/language-tutor/v8.version"
STAMP="${TMPDIR:-/tmp}/language-tutor-prewarm.stamp"

CLAUDE_BIN="$(command -v claude || true)"
if [[ -z "$CLAUDE_BIN" ]]; then
  log "skip: claude not on PATH"
  exit 0
fi

# --- Version check: drop the cache when claude CLI is upgraded -------------
# Fingerprint = mtime+size of the resolved claude entrypoint. Catches `npm i
# -g @anthropic-ai/claude-code@latest`, manual replacements, and dev builds.
# <10ms — no `claude --version` subprocess needed.
CLAUDE_REAL="$(readlink -f "$CLAUDE_BIN" 2>/dev/null || echo "$CLAUDE_BIN")"
FINGERPRINT="$(stat -c '%Y-%s' "$CLAUDE_REAL" 2>/dev/null \
            || stat -f '%m-%z' "$CLAUDE_REAL" 2>/dev/null \
            || echo unknown)"
STORED=""
[[ -r "$VERSION_FILE" ]] && STORED="$(cat "$VERSION_FILE" 2>/dev/null || true)"
if [[ "$FINGERPRINT" != "$STORED" ]]; then
  log "claude fingerprint changed ('$STORED' -> '$FINGERPRINT'); clearing v8 cache"
  rm -rf "$CACHE_DIR"
fi
mkdir -p "$CACHE_DIR"
printf '%s\n' "$FINGERPRINT" > "$VERSION_FILE"

# --- Debounce: skip if warmed in the last 60s ------------------------------
# Rapid session restarts shouldn't pay for repeated warm-ups (the V8 cache
# is already on disk from the previous run).
if [[ -f "$STAMP" ]]; then
  now=$(date +%s)
  mtime=$(stat -c %Y "$STAMP" 2>/dev/null || stat -f %m "$STAMP" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  if (( age < 60 )); then
    log "skip: warmed ${age}s ago"
    exit 0
  fi
fi
touch "$STAMP"

# --- Load model from config (same logic as grammar_check.sh) ---------------
MODEL="claude-haiku-4-5-20251001"
CONFIG_FILE="${HOME}/.claude/language-tutor.config"
# shellcheck disable=SC1090
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

log "spawning background warmup (model=${MODEL:-<follow /model>}, cache=$CACHE_DIR)"

# --- Fire-and-forget background warmup -------------------------------------
# Uses the SAME minimal-startup flag stack as grammar_check.sh so it warms
# the identical code path. Subshell + disown detaches it so this hook returns
# immediately and SessionStart doesn't block.
(
  export LANGUAGE_TUTOR_ACTIVE=1
  export NODE_COMPILE_CACHE="$CACHE_DIR"
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
  export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
  export CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1

  ARGS=(
    -p "ok"
    --system-prompt "Reply with just: k"
    --setting-sources ""
    --strict-mcp-config
    --mcp-config '{"mcpServers":{}}'
    --no-session-persistence
  )
  if [[ -n "${MODEL:-}" ]]; then
    ARGS+=(--model "$MODEL")
  fi

  "$CLAUDE_BIN" "${ARGS[@]}" </dev/null >/dev/null 2>&1
  rc=$?
  printf '[%s] prewarm: done (exit=%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" >> "$LOG_FILE"
) </dev/null >/dev/null 2>&1 &
disown

exit 0
