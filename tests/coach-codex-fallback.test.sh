#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/redpen-model-fallback.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_CODEX="$TEST_DIR/codex"
CALL_LOG="$TEST_DIR/calls.log"

cat > "$FAKE_CODEX" <<'EOF'
#!/usr/bin/env bash
set -u

model=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--model" ]]; then
    next=$((i + 1))
    model="${!next}"
    break
  fi
done

printf '%s' "$model" >> "$FAKE_CALL_LOG"
printf ' %q' "$@" >> "$FAKE_CALL_LOG"
printf '\n' >> "$FAKE_CALL_LOG"

case ",${FAKE_FAIL_MODELS:-}," in
  *,"$model",*)
    printf 'simulated failure for %s\n' "$model" >&2
    exit 7
    ;;
esac

printf '%s\n' \
  '[100] test prompt' \
  '──── Native style ────' \
  'test prompt'
EOF
chmod +x "$FAKE_CODEX"

run_coach() {
  : > "$CALL_LOG"
  printf '%s\n' '{"prompt":"test prompt"}' |
    HOME="$TEST_DIR" \
    REDPEN_CODEX_BIN="$FAKE_CODEX" \
    REDPEN_NO_TELEMETRY=1 \
    REDPEN_OUTPUT=structured \
    FAKE_CALL_LOG="$CALL_LOG" \
    FAKE_FAIL_MODELS="${1:-}" \
    bash "$ROOT/plugins/redpen-codex/shared/coach_codex.sh"
}

assert_line_count() {
  local expected="$1"
  local actual
  actual="$(wc -l < "$CALL_LOG" | tr -d ' ')"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %s calls, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

output="$(run_coach)"
assert_line_count 1
grep -q '^gpt-5\.6-luna ' "$CALL_LOG"
grep -q 'service_tier=\\"fast\\"' "$CALL_LOG"
grep -q 'features\.fast_mode=true' "$CALL_LOG"
grep -q '"status": "ok"' <<< "$output"

output="$(run_coach 'gpt-5.6-luna')"
assert_line_count 2
sed -n '2p' "$CALL_LOG" | grep -q '^gpt-5\.6-terra '
sed -n '2p' "$CALL_LOG" | grep -q 'service_tier=\\"fast\\"'
grep -q '"status": "ok"' <<< "$output"

output="$(run_coach 'gpt-5.6-luna,gpt-5.6-terra')"
assert_line_count 3
sed -n '3p' "$CALL_LOG" | grep -q '^gpt-5\.4-mini '
if sed -n '3p' "$CALL_LOG" | grep -q 'service_tier'; then
  printf 'gpt-5.4-mini fallback must not request Fast mode\n' >&2
  exit 1
fi
grep -q '"status": "ok"' <<< "$output"

output="$(run_coach 'gpt-5.6-luna,gpt-5.6-terra,gpt-5.4-mini')"
assert_line_count 3
[[ -z "$output" ]] || {
  printf 'expected empty output when every model fails\n' >&2
  exit 1
}

hook_json="$(
  REWRITTEN=$'[100] test prompt\n──── Native style ────\ntest prompt' \
  ORIGINAL_PROMPT='test prompt' \
  LT_LANGUAGE=english \
  REDPEN_SINGLE_LINE=1 \
  /usr/bin/env python3 "$ROOT/plugins/redpen-codex/shared/render_diff.py"
)"
HOOK_JSON="$hook_json" /usr/bin/env python3 -c '
import json
import os

message = json.loads(os.environ["HOOK_JSON"])["systemMessage"]
prefix = "\r\x1b[2K"
assert message.startswith(prefix), repr(message[:20])
assert message[len(prefix)] != "\n", repr(message[:20])
assert message[len(prefix)] != " ", repr(message[:20])
'

printf 'coach model fallback tests passed\n'
