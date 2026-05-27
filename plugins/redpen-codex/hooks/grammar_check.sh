#!/usr/bin/env bash
# UserPromptSubmit hook for Codex CLI.
#
# Keep this entrypoint thin so the Codex CLI plugin and the experimental
# Codex App launcher share the same coach implementation. The runner emits
# Codex's normal {"systemMessage": ...} hook JSON unless REDPEN_OUTPUT is
# set by another host.

set -u

_REDPEN_SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../shared" && pwd)" \
  || exit 0

exec bash "${_REDPEN_SHARED_DIR}/coach_codex.sh"
