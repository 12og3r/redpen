#!/usr/bin/env bash
# One-off probe: emit a single systemMessage containing many styling
# attempts so we can see which ones coco's TUI actually renders.
#
# Usage: temporarily swap coco.yaml's user_prompt_submit hook to point at
# this script, restart coco, send any prompt, and screenshot the rendered
# systemMessage. Revert coco.yaml when done.
#
# Each row prints a label (always plain) followed by the same word styled
# via a different mechanism. Whatever renders styled in coco is the channel
# we can use; anything that shows up as raw markup confirms that channel is
# unavailable.

set -u
LOG_FILE="${HOME}/.coco/redpen.log"
mkdir -p "$(dirname "$LOG_FILE")"
printf '[%s] probe: fired\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"

# Discard stdin (hook input). We don't need the user's prompt; we just want
# a trigger to emit our static probe.
cat >/dev/null 2>&1 || true

ESC=$'\033'
W="hello"

probes=$(cat <<PROBE
=== plain baseline ===
plain text:                       $W

=== ANSI SGR (expected: stripped — 2026-05 finding) ===
ANSI 16-color red:                ${ESC}[31m${W}${ESC}[0m
ANSI bright green bold:           ${ESC}[1;92m${W}${ESC}[0m
ANSI 256-color red:               ${ESC}[38;5;196m${W}${ESC}[0m
ANSI 24-bit RGB red:              ${ESC}[38;2;255;0;0m${W}${ESC}[0m
ANSI strikethrough:               ${ESC}[9m${W}${ESC}[0m
ANSI underline:                   ${ESC}[4m${W}${ESC}[0m
ANSI bold (no color):             ${ESC}[1m${W}${ESC}[0m

=== Markdown ===
markdown bold:                    **${W}**
markdown italic:                  *${W}*
markdown strikethrough:           ~~${W}~~
markdown inline code:             \`${W}\`
markdown link:                    [${W}](https://example.com)
markdown heading:                 # ${W}
markdown blockquote:              > ${W}

=== HTML-ish ===
HTML bold tag:                    <b>${W}</b>
HTML strong tag:                  <strong>${W}</strong>
HTML span color:                  <span style="color:red">${W}</span>
HTML font color:                  <font color="red">${W}</font>

=== Custom bracket markup (long shots) ===
bracket [red]:                    [red]${W}[/red]
brace {red}:                      {red:${W}}
ANSI-like \\u001b string:           \\u001b[31m${W}\\u001b[0m

=== Emoji (color via codepoint, no markup) ===
emoji red square + text:          🟥 ${W}
emoji green check + text:         ✅ ${W}
PROBE
)

# Use python for JSON encoding — preserves the raw ESC bytes and embedded
# quotes correctly. ensure_ascii=False so the emoji rows survive.
OUTPUT_JSON="$(PROBE_BODY="$probes" /usr/bin/env python3 -c '
import json, os
print(json.dumps({"systemMessage": os.environ["PROBE_BODY"]}, ensure_ascii=False))
')"

printf '%s\n' "$OUTPUT_JSON"
exit 0
