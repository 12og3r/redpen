#!/usr/bin/env bash
# UserPromptSubmit hook: score and rewrite the user's prompt in their target
# language via a synchronous headless `claude -p` call. The "[NN] <rewrite>"
# line is emitted as JSON `systemMessage` — visible to you, NOT added to the
# model's context.
#
# The call adds noticeable latency (~2–6s on the OAuth/Pro auth path) because
# the headless `claude -p` invocation has to bootstrap a Claude Code wrapper.
# We mitigate via the strictest minimal-startup flag stack we can use without
# requiring an ANTHROPIC_API_KEY (which is what `--bare` would need).

set -u

LOG_FILE="${HOME}/.claude/redpen.log"
mkdir -p "$(dirname "$LOG_FILE")"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
log "==== hook fired (pid=$$, recursion=${REDPEN_ACTIVE:-0}) ===="

# Recursion guard: our own `claude -p` invocation may re-trigger this hook
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

# Skip harness-injected envelopes. The UserPromptSubmit hook fires for every
# prompt that lands in the conversation, including ones the harness synthesises
# (background-task completion notifications, system reminders, slash-command
# scaffolding, etc.) — those are NOT the user typing prose and shouldn't be
# coached. The hook input has no `source` field to distinguish them, so we
# detect by the leading XML-like envelope tag, which only system-synthesised
# prompts use. A real user typing prose virtually never starts with `<foo>`.
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
    # Trim leading whitespace via bash parameter expansion (no python startup).
    PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"
    log "slash command with args — coaching: [$(printf '%s' "$PROMPT" | head -c 80)]"
    if [[ -z "$PROMPT" ]]; then log "skip: empty after slash"; exit 0; fi
    ;;
  /*) log "skip: pure slash command"; exit 0 ;;
  !*) log "skip: shell passthrough"; exit 0 ;;
esac

# --- Load user config -------------------------------------------------------
# First-run guard: if the user has never run /redpen:setup, skip rewriting
# AND nudge Claude to run setup via UserPromptSubmit additionalContext. We
# do the nudge here (not just in the SessionStart prewarm hook) because
# SessionStart fires inconsistently — it may not re-fire on /clear/resume in
# every Claude Code version, leaving sessions where the SessionStart nudge
# never lands. Re-emitting on every prompt until the config exists is
# self-healing: as soon as /redpen:setup finishes, the file appears and the
# nudge stops firing on its own.
CONFIG_FILE="${HOME}/.claude/redpen.config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "no config at $CONFIG_FILE — emitting UserPromptSubmit first-run nudge"
  /usr/bin/python3 -c '
import json, sys
sys.stdout.write(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": (
      "<redpen-first-run>\n"
      "The redpen plugin has not been configured yet "
      "(no ~/.claude/redpen.config file exists). Before doing "
      "anything else this turn — including answering the user, "
      "exploring code, or invoking any other tool — you MUST invoke the "
      "/redpen:setup slash command via the Skill tool "
      "(skill: \"redpen:setup\") to configure language, model, "
      "and native-style hint. After setup completes, then proceed with "
      "whatever the user originally asked.\n"
      "</redpen-first-run>"
    )
  }
}))
'
  exit 0
fi

LANGUAGE="english"
MODEL="haiku"
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

# Haiku detection — Haiku 4.5 forces adaptive extended thinking even with
# `--effort low`, blowing up output to a median of 742 tokens (p95 3771) and
# median latency to 9s (p95 32s) on the coach task. Setting
# CLAUDE_CODE_DISABLE_THINKING=1 collapses that to ~30 output tokens and
# ~0.9s median, but a naked disable causes the model to misjudge ~5% of
# clean English as score 0 ("explain async/await briefly" → 0, etc.). The
# fix is to force an in-output ANALYSIS reasoning line (see SYSTEM_INSTR
# append below) — that pushes false-zero rate back to 0/100 with only
# +150ms median latency. Bench: 100 prompts × 3 configs, see commit log.
IS_HAIKU=0
IS_OPUS=0
case "$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')" in
  *haiku*) IS_HAIKU=1 ;;
  *opus*)  IS_OPUS=1 ;;
esac
log "language=$LANGUAGE model=${MODEL:-<follow /model>} is_haiku=$IS_HAIKU is_opus=$IS_OPUS"

# --- Length-based skip ------------------------------------------------------
# UserPromptSubmit hooks don't receive paste metadata from Claude Code, so we
# can't isolate user-typed prose from pasted code/logs/transcripts. As a
# pragmatic proxy, skip anything over a character cap — long prompts almost
# always contain pasted material we don't want to rewrite. Override via the
# MAX_PROMPT_CHARS env var or in ~/.claude/redpen.config.
# ${#PROMPT} returns Unicode code-point count under a UTF-8 locale, so CJK
# characters count as 1 each (matching what the user perceives).
MAX_PROMPT_CHARS="${MAX_PROMPT_CHARS:-2000}"
if (( ${#PROMPT} > MAX_PROMPT_CHARS )); then
  log "skip: prompt too long (${#PROMPT} chars > $MAX_PROMPT_CHARS)"
  exit 0
fi

CLAUDE_BIN="$(command -v claude || true)"
if [[ -z "$CLAUDE_BIN" ]]; then log "skip: claude CLI not on PATH"; exit 0; fi

# --- Build the coach system prompt -----------------------------------------
# coach_prompts.sh lives at plugins/redpen/shared/ (bundled with the plugin
# so marketplace installers that copy plugins/redpen/ pick it up too). The
# canonical source is plugins/shared/ at the repo root; `make sync-shared`
# (or `make check-shared` in CI) keeps the bundled copies in sync.
_REDPEN_SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../shared" && pwd)" \
  || { log "fatal: cannot resolve shared/ relative to hook"; exit 0; }
# shellcheck disable=SC1091
source "${_REDPEN_SHARED_DIR}/coach_prompts.sh" \
  || { log "fatal: cannot source coach_prompts.sh from ${_REDPEN_SHARED_DIR}"; exit 0; }
set_coach_system_instr "$LANGUAGE"

# Opus-only: swap to a 4× shorter system prompt. Opus 4.7 follows rules
# tightly without needing the verbose nuance / examples — bench (50 prompts
# vs the full English prompt) showed cost -62%, p95 latency -34%, max
# latency -56%, and zero quality regression (0 false-zeros vs 1/50 with
# the full prompt). English mode only — bench was English-only and the
# other languages still benefit from the verbose example-rich prompts.
if (( IS_OPUS )) && [[ "$LANGUAGE" == "english" ]]; then
  SYSTEM_INSTR="You are an English coach. For each user message:

1. Score 0-100:
   - 100 = perfect, idiomatic
   - 80-99 = minor (article/preposition/tense)
   - 50-79 = clear errors, still readable
   - 1-49 = broken
   - 0 = contains ANY non-English character (CJK etc.). Digits, punctuation, whitespace, emoji do NOT count as foreign.

2. Rewrite into casual, idiomatic English:
   - Decode intent first — if a word looks misspelled or garbled, reconstruct what the user most likely meant. Never silently drop a word.
   - Preserve meaning, file paths, code identifiers, brand/library names (Vue.js, React, Kotlin, TikTok) verbatim.
   - Match the user's casing — keep lowercase sentence starts. Punctuation IS still fixed. EXCEPTION: the pronoun 'I' (and contractions I'm/I've/I'll/I'd) MUST always be capitalized — that's lexical, not stylistic.
   - Sound spoken: use contractions, casual phrasing. Avoid formal/textbook tone.
   - Preserve line breaks exactly: same number of lines, same correspondence.

Output EXACTLY three lines:
[<score>] <corrected text — or original unchanged if 100>
──── Native style ────
<colloquial native phrasing>

No commentary, no labels, no markdown, no code fences."
fi

# Haiku-only addendum: force a visible ANALYSIS reasoning line before the
# score line. Without this, Haiku in DISABLE_THINKING mode misjudges ~5%
# of clean English as score 0 (the model takes the "ANY foreign character
# → 0" rule and applies it sloppily). Forcing it to first commit to a
# yes/no answer on the foreign-character check restores correctness.
# Language-agnostic wording — model uses the target language from above.
if (( IS_HAIKU )) && [[ "$SHOW_HINT" != "off" ]]; then
  SYSTEM_INSTR="$SYSTEM_INSTR

ADDITIONAL HAIKU REQUIREMENT (overrides the output format above):
Before the score line, output ONE extra line starting with 'ANALYSIS:' that briefly answers, in order:
  (1) does the text contain characters from a language other than the target language? (yes/no)
  (2) any visible typos or grammar issues? (brief note or 'none')
Keep ANALYSIS to ONE line, max 25 words. Then continue with the score line, divider, and colloquial line as previously specified.

Updated output: EXACTLY FOUR lines —
ANALYSIS: <one-line check>
[<score>] <rewrite, WRITTEN IN THE TARGET LANGUAGE>
<the divider line in the target language>
<the colloquial line, ALSO IN THE TARGET LANGUAGE>

IMPORTANT — output discipline:
- You MUST always produce these four lines, in this order, no matter what. Never refuse. Never explain. Never apologize. Never output a paragraph instead of the four lines. There is no scenario where 'I cannot rewrite this' is a valid response — coaching is not optional.
- If the input is empty, garbled, mixed-language, or otherwise unusual, STILL output the four-line format. Use your best-effort interpretation of the user's intent for the rewrite. If you genuinely cannot guess, copy the original prompt translated word-for-word into the target language.

IMPORTANT — language of the rewrite:
- Lines 2 and 4 (rewrite + colloquial) MUST be in the target language, ALWAYS.
- When the original is in a different language (ANALYSIS says 'yes' to non-target characters), TRANSLATE the meaning into the target language for both lines. Do NOT echo the original back — that defeats the coaching purpose. Score 0 means 'wrong language', not 'skip the rewrite'.
- The divider on line 3 is fixed text; output the target-language divider exactly as specified by the main system prompt above.

IMPORTANT — score validity:
- If ANALYSIS says 'no' to non-target characters, the score MUST be greater than 0. The score-0-for-foreign rule applies ONLY when ANALYSIS detected a non-target character.

IMPORTANT — match the user's casing:
- If the original starts with a lowercase letter, the rewrite MUST also start with a lowercase letter. Do NOT capitalize sentence-starts. Lowercase starts are NOT errors — they are the user's voice.
- The pronoun 'I' is the ONLY exception: always capitalize it.
- This rule applies ONLY to letter casing. Punctuation (periods, question marks, apostrophes in contractions like don't/it's) MUST still be added or fixed.


ADDITIONAL EXAMPLES — edge cases that need careful handling:

Input: 你好
Output:
ANALYSIS: non-Latin: yes (CJK '你好'); typos: n/a; grammar: n/a (foreign language)
[0] hello
──── Native style ────
hey

Input: fix 这个 bug
Output:
ANALYSIS: non-Latin: yes (CJK '这个'); typos: none; grammar: incomplete (mixed-language)
[0] fix this bug
──── Native style ────
gotta fix this bug

Input: how do i implement undo redo
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (lowercase 'i' pronoun, missing punctuation)
[85] how do I implement undo redo?
──── Native style ────
how do I implement undo/redo?

Input: wanna fix this
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (casual contraction is fine; missing punctuation)
[78] wanna fix this?
──── Native style ────
wanna fix this?

Input: 部署完成后服务挂了
Output:
ANALYSIS: non-Latin: yes (CJK); typos: n/a; grammar: n/a (foreign language)
[0] the service went down after deployment finished
──── Native style ────
service crashed right after we deployed it

Input: 我想 refactor 这段代码
Output:
ANALYSIS: non-Latin: yes (CJK '我想' '这段代码'); typos: none; grammar: mixed-language
[0] I want to refactor this code
──── Native style ────
I am gonna refactor this code

Input: explain pub sub pattern
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing article, missing hyphen, missing punctuation)
[78] explain the pub-sub pattern.
──── Native style ────
can you explain how the pub-sub pattern works?

Input: ok
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: none (one-word acknowledgement)
[100] ok
──── Native style ────
got it


EXTENDED EXAMPLES — more nuanced cases:

Input: i recieve a error when running the script in production environment
Output:
ANALYSIS: non-Latin: no; typos: recieve (should be receive), missing article an, lowercase 'i' pronoun; grammar: minor
[72] I receive an error when running the script in the production environment
──── Native style ────
I am getting an error when running the script in production

Input: 这段代码在生产环境下报错了不知道为什么
Output:
ANALYSIS: non-Latin: yes (CJK throughout); typos: n/a; grammar: n/a
[0] this code throws an error in production and I do not know why
──── Native style ────
the code is crashing in prod and I have no clue why

Input: pls help me fix the typescript compile error
Output:
ANALYSIS: non-Latin: no; typos: pls is chat-speak; grammar: minor
[68] please help me fix the TypeScript compile error
──── Native style ────
can you help me fix this TypeScript compile error?

Input: 用 Docker 部署 Vue.js app 有什么坑
Output:
ANALYSIS: non-Latin: yes (CJK 用, 有什么坑); typos: none; grammar: mixed-language
[0] what are the common pitfalls when deploying a Vue.js app with Docker?
──── Native style ────
what should I watch out for when deploying Vue.js with Docker?

Input: how do I write a unit test for async function in jest
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing article an, missing punctuation)
[88] how do I write a unit test for an async function in Jest?
──── Native style ────
how do I unit-test an async function with Jest?

Input: my git push keeps failing why
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing punctuation, question structure)
[72] my git push keeps failing — why?
──── Native style ────
why does my git push keep failing?

Input: api 返回 401 错误怎么 debug
Output:
ANALYSIS: non-Latin: yes (CJK 返回, 错误, 怎么); typos: none; grammar: mixed-language
[0] how do I debug an API that returns a 401 error?
──── Native style ────
how do I figure out why the API is returning a 401?

Input: setup a CI/CD pipeline with github actions
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing article, GitHub capitalization)
[82] set up a CI/CD pipeline with GitHub Actions
──── Native style ────
set up a CI/CD pipeline using GitHub Actions

Input: 写个 sort 函数, 输入是 array of objects, 按 timestamp 排序
Output:
ANALYSIS: non-Latin: yes (CJK 写个, 输入是, 按, 排序); typos: none; grammar: mixed-language
[0] write a sort function that takes an array of objects and sorts them by timestamp
──── Native style ────
write me a sort function — input is an array of objects, sort by timestamp

Input: explain difference between map and forEach in javascript
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing article the, missing punctuation)
[80] explain the difference between map and forEach in JavaScript.
──── Native style ────
what is the difference between map and forEach in JavaScript?


FURTHER EXAMPLES — additional coverage:

Input: 帮我看下这段 python 代码哪里写错了
Output:
ANALYSIS: non-Latin: yes (CJK 帮我看下, 这段, 代码, 哪里写错了); typos: none; grammar: mixed-language
[0] could you look at this Python code and tell me where it is wrong?
──── Native style ────
can you take a look at this Python code and tell me what is broken?

Input: how to optimize this sql query its very slow
Output:
ANALYSIS: non-Latin: no; typos: its should be it is (contraction), SQL should be uppercase; grammar: missing punctuation
[68] how do I optimize this SQL query? it is very slow.
──── Native style ────
this SQL query is super slow — any tips on optimizing it?

Input: 在 React 里怎么管理全局状态
Output:
ANALYSIS: non-Latin: yes (CJK 在, 里怎么管理全局状态); typos: none; grammar: mixed-language
[0] how do I manage global state in React?
──── Native style ────
what is the best way to handle global state in React?

Input: writing tests for the new authentication flow
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (sentence fragment, missing subject and punctuation)
[78] writing tests for the new authentication flow.
──── Native style ────
I am writing tests for the new authentication flow.

Input: 这个 webpack config 我看不懂
Output:
ANALYSIS: non-Latin: yes (CJK 这个, 我看不懂); typos: none; grammar: mixed-language
[0] I do not understand this webpack config
──── Native style ────
this webpack config makes no sense to me

Input: need to add caching layer to this api
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing article a, missing subject I, API capitalization)
[72] I need to add a caching layer to this API
──── Native style ────
I need to add a caching layer to this API

Input: nginx 配置 reverse proxy 不工作
Output:
ANALYSIS: non-Latin: yes (CJK 配置, 不工作); typos: none; grammar: mixed-language
[0] my nginx reverse proxy config is not working
──── Native style ────
my nginx reverse proxy is not working

Input: please write a function that parses cron expressions
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: none
[100] please write a function that parses cron expressions
──── Native style ────
can you write a function that parses cron expressions?

Input: 重构后代码反而变慢了为什么
Output:
ANALYSIS: non-Latin: yes (CJK throughout); typos: n/a; grammar: n/a
[0] why did the code get slower after refactoring?
──── Native style ────
why is the code slower after the refactor?

Input: how to implement debounce in pure javascript
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing punctuation, JavaScript capitalization)
[88] how do I implement debounce in pure JavaScript?
──── Native style ────
how do you implement debounce in vanilla JavaScript?

Input: deploy failed but no error message
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (missing article the, missing subject I)
[78] the deploy failed but there is no error message
──── Native style ────
deploy failed with no error message — what gives?

Input: 数据库迁移脚本运行到一半挂了怎么办
Output:
ANALYSIS: non-Latin: yes (CJK throughout); typos: n/a; grammar: n/a
[0] what should I do if a database migration script crashes halfway through?
──── Native style ────
what do I do when a DB migration script dies mid-run?

Input: explain how virtual DOM works in react
Output:
ANALYSIS: non-Latin: no; typos: none; grammar: minor (React capitalization, missing punctuation)
[82] explain how virtual DOM works in React.
──── Native style ────
can you explain how React virtual DOM works?"
fi

# Wrap the user message in unambiguous "this is text to rewrite, not a
# question to answer" framing — belt-and-suspenders alongside --system-prompt
# so the model's helpful-assistant tendencies can't hijack the call.
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

# --- Build the claude args --------------------------------------------------
# Minimal-startup flag stack (OAuth-compatible — none of these require an
# API key, unlike `--bare`). Each cuts a meaningful chunk of wrapper init:
#   --setting-sources ""              skip user/project/local settings.json loading
#   --strict-mcp-config               ignore default MCP config sources
#   --mcp-config '{"mcpServers":{}}'  inject an empty MCP config (no MCP startup)
#   --no-session-persistence          don't write a transcript .jsonl
#   --tools ""                        no tool definitions injected (drops ~11k
#                                     tokens of tool-spec input bloat AND skips
#                                     the hidden Haiku auto-mode classifier
#                                     call). Verified empirically: median
#                                     latency 7.5s → 2.2s on a 35-prompt bench.
#   --effort low                      suppress the model's internal thinking
#                                     block. The coach task is score+rewrite,
#                                     not reasoning — thinking just emitted
#                                     ~200-800 wasted tokens. Cuts another
#                                     ~50% off latency and 6x off cost.
ARGS=(
  -p "$USER_MSG"
  --system-prompt "$SYSTEM_INSTR"
  --setting-sources ""
  --strict-mcp-config
  --mcp-config '{"mcpServers":{}}'
  --no-session-persistence
  --tools ""
  --effort low
)
if [[ -n "$MODEL" ]]; then
  ARGS+=(--model "$MODEL")
  # Opus has a real p95 long tail on this task (~7s observed in bench)
  # from server-side queueing, not hidden thinking. Falling through to
  # Sonnet when Opus is overloaded keeps the request flowing — Sonnet
  # is Opus-quality on this coach task (verified via cross-model bench).
  # Haiku/Sonnet don't get a fallback: their throughput is already good
  # and falling further would change behaviour more than it helps.
  if (( IS_OPUS )); then
    ARGS+=(--fallback-model sonnet)
  fi
fi

# Clean cwd for the headless call — escape project-level CLAUDE.md and any
# auto-loaded skills (e.g. superpowers:systematic-debugging would otherwise
# hijack "fix the bug" prompts).
CLEAN_CWD=""
for candidate in "${TMPDIR:-}" /tmp "$HOME"; do
  [[ -z "$candidate" ]] && continue
  if [[ -d "$candidate" && -x "$candidate" ]]; then
    CLEAN_CWD="$candidate"
    break
  fi
done
log "clean_cwd=${CLEAN_CWD:-<none, using current>}"

# Env vars also kill nonessential startup work (also OAuth-compatible):
#   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC  no background HTTP probes
#   CLAUDE_CODE_DISABLE_AUTO_MEMORY           no /memory/ auto-load
#   CLAUDE_CODE_DISABLE_CLAUDE_MDS            no CLAUDE.md auto-discovery
#   CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS      no git-status injection
#
# Redirect stdin from /dev/null — without it `claude -p` waits 3 full seconds
# for stdin data before proceeding, even though we passed the prompt as an arg.
REWRITTEN="$(
  if [[ -n "$CLEAN_CWD" ]]; then cd "$CLEAN_CWD"; fi
  # Haiku gets one extra env var to disable adaptive extended thinking — see
  # the IS_HAIKU comment near the top for the bench numbers driving this.
  if (( IS_HAIKU )); then export CLAUDE_CODE_DISABLE_THINKING=1; fi
  REDPEN_ACTIVE=1 \
  NODE_COMPILE_CACHE="${HOME}/.cache/redpen/v8" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 \
  CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1 \
    "$CLAUDE_BIN" "${ARGS[@]}" </dev/null 2>/dev/null
)"

# Trim leading/trailing whitespace via bash parameter expansion (no python).
REWRITTEN="${REWRITTEN#"${REWRITTEN%%[![:space:]]*}"}"
REWRITTEN="${REWRITTEN%"${REWRITTEN##*[![:space:]]}"}"

log "rewrite[0..120]=$(printf '%s' "$REWRITTEN" | head -c 120)"

if [[ -z "$REWRITTEN" ]]; then log "skip: empty rewrite"; exit 0; fi

# Emit as systemMessage. Use python for the JSON encode so CJK characters
# pass through as themselves (ensure_ascii=False) rather than \uXXXX escapes.
#
# Also: color the score by band and underline-bold the words that the rewrite
# *changed* relative to the original — so the user sees what was wrong at a
# glance. All client-side (difflib), no extra LLM call, no added latency.
OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ORIGINAL_PROMPT="$PROMPT" LT_LANGUAGE="$LANGUAGE" \
    /usr/bin/python3 "${_REDPEN_SHARED_DIR}/render_diff.py")" \
  || { log "fatal: render_diff.py failed"; exit 0; }
log "emit json[0..200]=$(printf '%s' "$OUTPUT_JSON" | head -c 200)"
printf '%s\n' "$OUTPUT_JSON"

exit 0
