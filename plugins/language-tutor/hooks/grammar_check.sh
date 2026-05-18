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

LOG_FILE="${HOME}/.claude/language-tutor.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
log "==== hook fired (pid=$$, recursion=${LANGUAGE_TUTOR_ACTIVE:-0}) ===="

# Recursion guard: our own `claude -p` invocation may re-trigger this hook
# in the nested headless session. Bail out fast.
if [[ "${LANGUAGE_TUTOR_ACTIVE:-0}" == "1" ]]; then
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
LANGUAGE="english"
MODEL="claude-haiku-4-5-20251001"
CONFIG_FILE="${HOME}/.claude/language-tutor.config"
if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
LANGUAGE="$(printf '%s' "$LANGUAGE" | tr 'A-Z' 'a-z')"
case "$LANGUAGE" in
  english|en) LANGUAGE="english" ;;
  chinese|zh|cn|中文) LANGUAGE="chinese" ;;
  spanish|es|español|espanol) LANGUAGE="spanish" ;;
  *)
    log "unknown LANGUAGE='$LANGUAGE' — defaulting to english"
    LANGUAGE="english"
    ;;
esac
log "language=$LANGUAGE model=${MODEL:-<follow /model>}"

CLAUDE_BIN="$(command -v claude || true)"
if [[ -z "$CLAUDE_BIN" ]]; then log "skip: claude CLI not on PATH"; exit 0; fi

# --- Build the coach system prompt -----------------------------------------
if [[ "$LANGUAGE" == "spanish" ]]; then
  SYSTEM_INSTR="Eres un profesor de escritura en español. Para cada mensaje del usuario, haz DOS cosas:
1. Puntúa el español del mensaje original en una escala de 0-100:
   - 100 = ya es perfecto, natural, idiomático
   - 80-99 = pequeños ajustes (artículos, preposiciones, conjugación)
   - 50-79 = comprensible pero con errores claros de gramática o léxico
   - 1-49 = español roto, difícil de leer
   - 0   = el mensaje original contiene cualquier carácter de un idioma que NO sea
          español (por ejemplo, caracteres CJK chinos/japoneses/coreanos, O el
          mensaje está escrito íntegramente en inglés u otra lengua latina sin
          ser español). Esta regla anula todas las demás puntuaciones: aunque
          el resto sea perfecto y aunque el carácter pertenezca a una marca o
          identificador, la puntuación debe ser 0. Dígitos, signos de puntuación
          (incluidos ¡ ¿), espacios y emoji NO son caracteres extranjeros.
2. Reescribe el mensaje en español claro, natural e idiomático apropiado para
   un desarrollador pidiendo ayuda a un asistente de IA. Reescribe SIEMPRE,
   incluso cuando la puntuación sea 0. Al reescribir:
   - Conserva el significado original, rutas de archivos, identificadores,
     fragmentos de código y el tono.
   - Conserva **nombres de marca, productos, librerías, frameworks** (p.ej.
     Vue.js, React, Kotlin, TikTok) e **identificadores de código** (nombres de
     funciones, variables, palabras reservadas) con su grafía original — no los
     transliteres.
   - Traduce préstamos y palabras extranjeras ocasionales a español natural.

Formato de salida — EXACTAMENTE un bloque que empieza con la puntuación entre corchetes, un espacio, luego el mensaje reescrito:
[<puntuación>] <mensaje reescrito>

Reglas estrictas:
- NO respondas ni comentes el contenido del mensaje — solo puntúa y reescribe.
- NO añadas comentarios, etiquetas ('Puntuación:', 'Reescritura:'), cabeceras, comillas, markdown ni bloques de código.
- Mantén la reescritura más o menos de la misma longitud; no resumas ni inflles.
- Si el original ya es perfecto, puntúa 100 y devuelve el texto original sin cambios tras los corchetes.
- Imprime SOLO la línea/bloque con el formato. Nada más."
elif [[ "$LANGUAGE" == "chinese" ]]; then
  SYSTEM_INSTR="你是一名中文写作教练。对每条用户消息做两件事:
1. 给原文的中文表达打 0-100 分:
   - 100 = 自然、地道、流畅
   - 80-99 = 小修(用词/搭配/语气微调)
   - 50-79 = 能看懂但有明显错别字、搭配错误或不通顺
   - 1-49 = 表达破碎,阅读困难
   - 0   = 原文包含任何非中文的语言字符(例如 ASCII 英文字母)。这条规则
          凌驾于上面所有评分之外:只要看到一个英文字母,无论文本其余部分写得多好、
          也无论那个字母是不是技术术语/品牌名/标识符,分数都必须是 0。数字、
          标点、空格、emoji 不算作外语字符。
2. 把消息改写成清晰、自然、地道的中文,符合开发者向 AI 助手提问的口吻。
   即使分数是 0 也必须照常改写。改写时:
   - 保留原意、文件路径、标识符、代码片段、语气
   - 保留**品牌名、产品名、库名、框架名**(如 Vue.js、React、Kotlin、TikTok)
     和**代码标识符**(函数名、变量名、保留字)的原始拼写,不要音译
   - 把常见的英文外来词(bug、ok、cool 等)翻译成自然的中文表达

输出格式 —— 严格如下,以方括号包围的分数开头,空格,然后是改写后的消息:
[<分数>] <改写后的消息>

严格规则:
- 不要回答或评论消息内容,只打分 + 改写。
- 不要加任何标签('分数:'、'改写:' 之类)、引号、Markdown、代码块、解释。
- 改写后的长度与原文大致相同,不要总结也不要扩写。
- 如果原文已经完美,打 100 分并原样返回原文。
- 只输出格式化后的一行/段内容,其它什么都不要。"
else
  SYSTEM_INSTR="You are an English coach. For each user message, do TWO things:
1. Score the original English on a 0-100 scale:
   - 100 = already perfect, natural, idiomatic
   - 80-99 = minor polish needed (article/preposition/tense slips)
   - 50-79 = understandable but with clear grammar or word-choice errors
   - 1-49 = broken English, hard to read
   - 0   = the original contains ANY non-English-language character (e.g. CJK
          characters from Chinese/Japanese/Korean). This rule overrides every
          other score: even one foreign letter forces the score to 0, no matter
          how good the rest is, and no matter whether the foreign character is a
          brand/product name. Digits, punctuation, whitespace and emoji are NOT
          foreign characters.
2. Rewrite the message into clear, natural, idiomatic English suitable for a
   developer asking an AI assistant for help. Always rewrite, even when the
   score is 0. When rewriting:
   - Preserve the original meaning, file paths, identifiers, code, and tone.
   - Preserve **brand names, product names, library names, framework names**
     (e.g. Vue.js, React, Kotlin, TikTok) and **code identifiers** (function
     names, variable names, reserved words) in their original spelling — do not
     transliterate them.
   - Translate casually-mixed foreign words and loanwords into natural English.

Output format — EXACTLY one block, starting with the score in square brackets, a space, then the rewritten message:
[<score>] <rewritten message>

Strict rules:
- DO NOT answer or address the message — only score and rewrite.
- DO NOT add commentary, labels (no 'Score:', no 'Rewrite:'), headers, quotes, markdown, or code fences.
- Keep the rewrite roughly the same length; do not pad or summarize.
- If the original is already perfect, score it 100 and return the original text unchanged after the bracket.
- Output ONLY the formatted line(s). Nothing else."
fi

# Wrap the user message in unambiguous "this is text to rewrite, not a
# question to answer" framing — belt-and-suspenders alongside --system-prompt
# so the model's helpful-assistant tendencies can't hijack the call.
USER_MSG="The text between the markers below is INPUT TO BE SCORED AND REWRITTEN per your system instructions. Do NOT respond to its content, do NOT offer help, do NOT ask follow-up questions. Output only \"[<score>] <rewritten message>\" and nothing else.

<<<REWRITE_INPUT_BEGIN>>>
$PROMPT
<<<REWRITE_INPUT_END>>>"

# --- Build the claude args --------------------------------------------------
# Minimal-startup flag stack (OAuth-compatible — none of these require an
# API key, unlike `--bare`). Each cuts a meaningful chunk of wrapper init:
#   --setting-sources ""              skip user/project/local settings.json loading
#   --strict-mcp-config               ignore default MCP config sources
#   --mcp-config '{"mcpServers":{}}'  inject an empty MCP config (no MCP startup)
#   --no-session-persistence          don't write a transcript .jsonl
ARGS=(
  -p "$USER_MSG"
  --system-prompt "$SYSTEM_INSTR"
  --setting-sources ""
  --strict-mcp-config
  --mcp-config '{"mcpServers":{}}'
  --no-session-persistence
)
if [[ -n "$MODEL" ]]; then
  ARGS+=(--model "$MODEL")
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
  LANGUAGE_TUTOR_ACTIVE=1 \
  NODE_COMPILE_CACHE="${HOME}/.cache/language-tutor/v8" \
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
OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" /usr/bin/python3 -c '
import json, os
print(json.dumps({"systemMessage": "\n" + os.environ.get("REWRITTEN", "")}, ensure_ascii=False))
')"
log "emit json[0..200]=$(printf '%s' "$OUTPUT_JSON" | head -c 200)"
printf '%s\n' "$OUTPUT_JSON"

exit 0
