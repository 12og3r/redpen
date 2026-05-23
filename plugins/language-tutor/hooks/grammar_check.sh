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
# First-run guard: if the user has never run /language-tutor:setup, skip
# rewriting entirely. The SessionStart hook is responsible for nudging the
# user (or Claude) to run setup; without a config we shouldn't silently
# coach in whichever language the defaults happen to be.
CONFIG_FILE="${HOME}/.claude/language-tutor.config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "skip: no config at $CONFIG_FILE — user needs to run /language-tutor:setup first"
  exit 0
fi

LANGUAGE="english"
MODEL="sonnet"
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
# MAX_PROMPT_CHARS env var or in ~/.claude/language-tutor.config.
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
2. Reescribe el mensaje en español **conversacional, coloquial e idiomático**
   — como un desarrollador real escribiría en un chat o DM a un asistente de
   IA. Reescribe SIEMPRE, incluso cuando la puntuación sea 0. Al reescribir:
   - **Decodifica la intención ANTES de reescribir — preservar el significado
     es innegociable.** Si una palabra está mal escrita, deformada, suena
     fonéticamente rara o garabateada (p.ej. 'wacond' casi seguro es
     'weekend', 'recivir' es 'recibir', 'fuites' es 'fuiste'), reconstruye lo
     que el usuario **más probablemente quiso decir** y conserva ESE
     significado en la reescritura. Adivina por fonética, similitud visual,
     proximidad de teclas y contexto. NUNCA descartes silenciosamente una
     palabra que no entiendas, ni reescribas el mensaje con otro significado
     solo para que quede gramatical. Si realmente no puedes adivinar, deja la
     palabra original tal cual en lugar de borrarla.
   - **Suena hablado, no escrito.** Usa contracciones naturales (del, al), el
     tono de 'tú' (no 'usted'), y un registro casual y directo. Evita los
     registros formales, librescos o académicos — no conviertas 'arregla el
     bug' en 'Por favor, sírvase resolver el defecto del software', y no
     rellenes con 'tenga la amabilidad de', 'le agradecería que', etc.
   - **Conserva los saltos de línea EXACTAMENTE.** Si el original abarca varias
     líneas, la reescritura debe abarcar el mismo número de líneas, y cada
     línea reescrita debe corresponder a la línea original en la misma
     posición. Nunca fusiones varias líneas originales en una sola, ni
     dividas una línea original en varias. Las líneas en blanco permanecen
     en blanco.
   - Conserva el significado original, rutas de archivos, identificadores,
     fragmentos de código y el tono.
   - Conserva **nombres de marca, productos, librerías, frameworks** (p.ej.
     Vue.js, React, Kotlin, TikTok) e **identificadores de código** (nombres de
     funciones, variables, palabras reservadas) con su grafía original — no los
     transliteres.
   - Traduce préstamos y palabras extranjeras ocasionales a español natural.
   - **Respeta las mayúsculas del usuario.** NO obligues a poner mayúscula al
     inicio de la oración. Si el usuario escribió la primera letra en
     minúscula, mantenla en minúscula al reescribir. Una minúscula al inicio
     NO es un error — no la 'arregles' ni bajes la puntuación por eso.
   - **La puntuación SÍ se sigue corrigiendo.** Esta regla de mayúsculas
     aplica SOLO a la capitalización de letras — NO se extiende a la
     puntuación. La puntuación faltante o incorrecta (puntos, comas, signos
     de interrogación/exclamación de apertura y cierre ¿? ¡!, apóstrofos,
     etc.) DEBE añadirse o corregirse en la reescritura, igual que cualquier
     otro error gramatical. No 'preserves' un punto que falta como sí
     preservas una minúscula inicial.

Formato de salida — EXACTAMENTE tres líneas:
[<puntuación>] <mensaje corregido — o el texto original sin cambios si la puntuación es 100>
──── Estilo nativo ────
<la forma más natural y coloquial que usaría un hablante nativo>

Ejemplo:
Entrada: quiero checar si el hook esta funcionando
Salida:
[70] quiero verificar si el hook está funcionando.
──── Estilo nativo ────
¿a ver si el hook jala?

Reglas estrictas:
- NO respondas ni comentes el contenido del mensaje — solo puntúa y reescribe.
- NO añadas comentarios, etiquetas ('Puntuación:', 'Reescritura:'), cabeceras, comillas, markdown ni bloques de código.
- Mantén la reescritura más o menos de la misma longitud; no resumas ni inflles.
- Línea 1: si la puntuación es 100, devuelve el original sin cambios. En caso contrario, devuelve la versión corregida.
- Línea 2: SIEMPRE escribe EXACTAMENTE '──── Estilo nativo ────' como separador — sin contenido adicional en esta línea.
- Línea 3: la reformulación coloquial de la Línea 1 ÚNICAMENTE. El significado DEBE ser idéntico a la Línea 1 — mismo sujeto, misma acción, misma intención. Solo cambia el estilo para sonar más hablado y casual. Incluso si la puntuación es 100, NUNCA omitas las líneas 2 y 3.
- Imprime SOLO las tres líneas. Nada más."
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
2. 把消息改写成**口语化、地道**的中文 —— 像一个真实的开发者在 IM/聊天里
   向 AI 助手提问的那种口吻。即使分数是 0 也必须照常改写。改写时:
   - **先理解意图,再改写 —— 保留原意不可妥协。**
     如果某个词看起来是拼写错误、形近字误、谐音字、拼音残缺或键入错位
     (例如 'wacond' 几乎肯定是 'weekend','末后'通常是'末尾','你门'是
     '你们'),必须先**重建用户最可能想表达的意思**,然后保留那个意思去
     改写。从发音、字形、键盘相邻、上下文去猜。绝对不能因为看不懂一个
     词就把它删掉,也绝对不能为了让句子通顺就把消息改成完全不同的意思。
     实在猜不出来,就**保留原词不动**,也不要删。
   - **像说话,不像写文章。** 该用语气词('吧'、'呢'、'啊'、'嘛')的地方就用,
     该用'这个/那个/搞/弄'的地方就用,简洁直接。坚决避免书面体、新闻体、
     教科书体的公文腔 —— 不要把'修一下这个 bug'改成'对该问题进行修复',
     不要硬塞'如下所示'、'综上所述'、'针对……'这种词
   - **完整保留换行结构。** 如果原文有多行,改写后必须保留同样的行数,且
     每一行改写都对应原文同一位置的那一行。绝对不要把多行合并成一行,也不
     要把一行拆成多行。空行依然是空行。
   - 保留原意、文件路径、标识符、代码片段、语气
   - 保留**品牌名、产品名、库名、框架名**(如 Vue.js、React、Kotlin、TikTok)
     和**代码标识符**(函数名、变量名、保留字)的原始拼写,不要音译
   - 把常见的英文外来词(bug、ok、cool 等)翻译成自然的中文表达

输出格式 —— 严格三行:
[<分数>] <语法修正后的消息 —— 若分数为 100 则原样返回原文>
──── 地道说法 ────
<最地道、口语化的表达方式>

示例:
输入:我想检查一下这个钩子有没有正常工作
输出:
[90] 我想检查一下这个钩子有没有正常工作。
──── 地道说法 ────
看看这个钩子跑起来没有？

严格规则:
- 不要回答或评论消息内容,只打分 + 改写。
- 不要加任何标签('分数:'、'改写:' 之类)、引号、Markdown、代码块、解释。
- 改写后的长度与原文大致相同,不要总结也不要扩写。
- 第一行:若分数为 100,原文无需修正,原样返回;否则返回语法修正后的版本。
- 第二行:必须原样输出 '──── 地道说法 ────' 作为分隔线 —— 这一行不要带任何其它内容。
- 第三行:对第一行的口语化改写,且意思必须与第一行完全一致 —— 主语、动作、意图都不变,只改变风格使其听起来更口语、更随意。即使分数是 100 也绝对不能省略第二、三行。
- 只输出这三行,其它什么都不要。"
elif [[ "$LANGUAGE" == "japanese" ]]; then
  SYSTEM_INSTR="あなたは日本語ライティングのコーチです。ユーザーの各メッセージに対して、2 つのことを行ってください:
1. 元の日本語を 0-100 のスケールで採点する:
   - 100 = 既に完璧で、自然で、ネイティブらしい日本語
   - 80-99 = 小さな修正のみ必要(助詞・活用・敬語の微調整など)
   - 50-79 = 意味は通じるが、文法や語彙に明らかな誤りがある
   - 1-49 = 壊れていて読みにくい日本語
   - 0   = 元のメッセージに日本語以外の言語の文字が 1 つでも含まれる場合
          (例: 簡体字中国語のみで書かれた文字列、英語や他のラテン系言語のみで
          書かれたメッセージ)。このルールは他のすべての採点を上書きします:
          残りがどれほど完璧でも、その文字がブランド名や識別子であっても、
          スコアは 0 でなければなりません。数字、記号、空白、emoji は外国語
          文字とは見なしません。なお、日本語の中で自然に使われる漢字
          (常用漢字)・ひらがな・カタカナはすべて日本語の文字として扱います。
2. メッセージを **会話的で自然な日本語** に書き換える —— 実際の開発者が
   チャットや DM で AI アシスタントに話しかけるような口調で。スコアが 0 の
   場合でも必ず書き換えること。書き換えるときは:
   - **書き換える前に意図を読み取る —— 意味の保持は絶対条件。**
     スペルミス、誤変換、音便のような崩れ、文字化けっぽい単語があった場合
     (例: 'tukau' はおそらく '使う'、'すきま' は '隙間'、'なんで' は理由を
     聞く 'なんで(=なぜ)' か手段の 'なんで(=何で)' か文脈で判断)、ユーザーが
     **最も言いたかったこと** を復元し、その意味を保ったまま書き換える。
     音、見た目、キーボードの近接、文脈から推測する。読み取れない単語を
     黙って消したり、文法を整えるために違う意味にしたりしては絶対にいけない。
     どうしても推測できなければ、その単語を元のまま残す。
   - **書き言葉ではなく話し言葉に。** 終助詞('ね'、'よ'、'かな'、'っけ')や、
     '〜してる/〜じゃない/〜しちゃう' のような縮約形を自然に使う。簡潔で
     直接的に。硬い書面語・新聞調・教科書調を避ける —— 'バグを直す' を
     'バグを修正する次第である' などにしない。'拝啓'、'〜の儀'、'〜致したく'
     のような形式張った表現を入れない。
   - **改行構造をそのまま保持する。** 元が複数行なら、書き換えも同じ行数で、
     各行が元の同じ位置の行に対応するようにする。複数の行を 1 行にまとめたり、
     1 行を複数行に分割したりしない。空行はそのまま空行。
   - 元の意味、ファイルパス、識別子、コードスニペット、トーンを保持する。
   - **ブランド名・製品名・ライブラリ名・フレームワーク名**(例: Vue.js、
     React、Kotlin、TikTok)と **コード識別子**(関数名、変数名、予約語)は
     元のスペルのまま残し、カタカナ転写しない。
   - 'bug'、'ok'、'cool' のようなカジュアルに混ざる外来語は、自然な日本語に
     翻訳する(必要に応じてカタカナのままでも可)。

出力フォーマット —— 厳密に 3 行:
[<スコア>] <文法修正後のメッセージ —— スコアが 100 なら原文をそのまま返す>
──── ネイティブの言い方 ────
<ネイティブが実際に話すような最も自然で口語的な表現>

例:
入力: フックが正常に動いているかチェックしたいです
出力:
[90] フックが正常に動いているかチェックしたいです。
──── ネイティブの言い方 ────
フックちゃんと動いてるか見たいんだけど。

厳格なルール:
- メッセージの内容に答えたりコメントしたりしない —— 採点と書き換えのみ。
- 'スコア:'、'書き換え:' のようなラベル、引用符、Markdown、コードブロック、
  説明を付けない。
- 書き換えの長さは元とおおむね同じに保つ。要約も水増しもしない。
- 1 行目: スコアが 100 なら原文をそのまま返す。そうでなければ文法修正後の
  バージョンを返す。
- 2 行目: 必ず正確に '──── ネイティブの言い方 ────' を区切り線として
  出力する —— この行に他の内容を入れない。
- 3 行目: 1 行目の口語的な言い換え。意味は 1 行目と完全に同じでなければ
  ならない —— 主語・動作・意図はそのまま、スタイルだけを話し言葉に寄せる。
  スコアが 100 でも 2 行目と 3 行目を絶対に省略しない。
- この 3 行だけを出力する。それ以外は何も出さない。"
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
2. Rewrite the message into **conversational, idiomatic** English — the way a
   real developer would type in chat or DM to an AI assistant. Always rewrite,
   even when the score is 0. When rewriting:
   - **Decode intent BEFORE rewriting — preserving meaning is non-negotiable.**
     If a word looks misspelled, mangled, phonetic, or garbled (e.g. 'wacond'
     almost certainly means 'weekend', 'recieve' means 'receive', 'how is you'
     means 'how are you'), reconstruct what the user **most likely meant** and
     keep THAT meaning in the rewrite. Guess from phonetics, visual similarity,
     keyboard adjacency, and surrounding context. NEVER silently drop a word
     you cannot parse, and NEVER rewrite the message into a different meaning
     just to make it grammatical. If you truly cannot guess, keep the original
     word as-is rather than deleting it.
   - **Sound spoken, not written.** Use contractions (don't, can't, it's, I'm,
     won't, that's). Keep it casual, direct, and concise. Avoid stiff, formal,
     or textbook phrasings — don't turn 'fix the bug' into 'Please resolve this
     software defect', and don't pad with 'kindly', 'could you please', etc.
   - **Preserve line breaks exactly.** If the original spans multiple lines,
     the rewrite must span the same number of lines, with each rewrite line
     corresponding to the original line at the same position. Never merge
     multiple original lines into one, and never split one original line into
     multiple. Blank lines stay blank lines.
   - Preserve the original meaning, file paths, identifiers, code, and tone.
   - Preserve **brand names, product names, library names, framework names**
     (e.g. Vue.js, React, Kotlin, TikTok) and **code identifiers** (function
     names, variable names, reserved words) in their original spelling — do not
     transliterate them.
   - Translate casually-mixed foreign words and loanwords into natural English.
   - **Match the user's casing.** Do NOT enforce sentence-start capitalization.
     If the user wrote a lowercase first letter, keep it lowercase in the
     rewrite. Lowercase sentence starts are NOT errors — do not 'fix' them
     and do not let them lower the score. (The pronoun 'I' is still always
     capitalized; that's lexical, not sentence-position.)
   - **Punctuation IS still corrected.** This casing rule applies ONLY to
     letter casing — it does NOT extend to punctuation. Missing or wrong
     punctuation (periods, commas, question marks, apostrophes in
     contractions like don't/it's, etc.) MUST still be added or fixed in
     the rewrite, just like any other grammar issue. Do not 'preserve' a
     missing period the way you preserve a lowercase start.

Output format — EXACTLY three lines:
[<score>] <corrected message — or the original text unchanged if score is 100>
──── Native style ────
<the most natural, colloquial phrasing a native speaker would use>

Example:
Input: i want check if hook working
Output:
[55] i want to check if the hook is working.
──── Native style ────
wanna see if the hook's working?

Strict rules:
- DO NOT answer or address the message — only score and rewrite.
- DO NOT add commentary, labels (no 'Score:', no 'Rewrite:'), headers, quotes, markdown, or code fences.
- Keep the rewrite roughly the same length; do not pad or summarize.
- Line 1: if score is 100 the original needs no correction — return it unchanged. Otherwise return the grammar-corrected version.
- Line 2: ALWAYS output EXACTLY '──── Native style ────' as a divider — no other content on this line.
- Line 3: the colloquial rephrasing of Line 1 ONLY. The meaning MUST be identical to Line 1 — same subject, same action, same intent. Only change the style to sound more spoken and casual. Even if score is 100, NEVER omit lines 2 and 3.
- Output ONLY the three lines. Nothing else."
fi

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
   - Match the user's casing — keep lowercase sentence starts. Punctuation IS still fixed.
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

IMPORTANT — language of the rewrite:
- Lines 2 and 4 (rewrite + colloquial) MUST be in the target language, ALWAYS.
- When the original is in a different language (ANALYSIS says 'yes' to non-target characters), TRANSLATE the meaning into the target language for both lines. Do NOT echo the original back — that defeats the coaching purpose. Score 0 means 'wrong language', not 'skip the rewrite'.
- The divider on line 3 is fixed text; output the target-language divider exactly as specified by the main system prompt above.

IMPORTANT — score validity:
- If ANALYSIS says 'no' to non-target characters, the score MUST be greater than 0. The score-0-for-foreign rule applies ONLY when ANALYSIS detected a non-target character."
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
#
# Also: color the score by band and underline-bold the words that the rewrite
# *changed* relative to the original — so the user sees what was wrong at a
# glance. All client-side (difflib), no extra LLM call, no added latency.
OUTPUT_JSON="$(REWRITTEN="$REWRITTEN" ORIGINAL_PROMPT="$PROMPT" LT_LANGUAGE="$LANGUAGE" /usr/bin/python3 -c '
import json, os, re, difflib

RESET = "\033[0m"
DEFAULT = "\033[1;36m"  # bold cyan — body default (every char is cyan unless overridden)
ADDED = "\033[1;32m"    # bold green — words AI added that were not in the original
DELETE = "\033[9;31m"   # red strikethrough — removed text
HINT   = "\033[0;33m"   # yellow — colloquial hint line

def score_color(s):
    if s >= 100: return "\033[1;92m"  # bold bright green
    if s >= 80:  return "\033[1;32m"  # bold green
    if s >= 50:  return "\033[1;33m"  # bold yellow
    if s >= 1:   return "\033[1;31m"  # bold red
    return "\033[1;91m"               # bold bright red (score 0)

def tokenize(s, lang):
    # Chinese/Japanese: char-level for CJK/kana chars, contiguous non-CJK
    # runs as one token.
    # English/Spanish: word-level, but punctuation is split out as its own
    # token so a missing-period fix highlights only the period — not the
    # whole preceding word. Whitespace is kept as separate tokens so
    # join(tokens) reconstructs the original exactly.
    if lang in ("chinese", "japanese"):
        out, buf = [], []
        for ch in s:
            cjk = ("一" <= ch <= "鿿"
                   or "　" <= ch <= "〿"
                   or "぀" <= ch <= "ヿ"
                   or "＀" <= ch <= "￯")
            if cjk:
                if buf: out.append("".join(buf)); buf = []
                out.append(ch)
            else:
                buf.append(ch)
        if buf: out.append("".join(buf))
        return out
    return re.findall(r"\w+|[^\w\s]|\s+", s, flags=re.UNICODE)

raw = os.environ.get("REWRITTEN", "")
prompt = os.environ.get("ORIGINAL_PROMPT", "")
language = os.environ.get("LT_LANGUAGE", "english")

# Haiku-only: model emits a leading "ANALYSIS: ..." line before the score
# (see IS_HAIKU block in grammar_check.sh) to prevent misjudging clean
# English as score 0. The user does not need to see it — strip it before
# rendering. NOTE: avoid apostrophes here — this comment lives inside a
# single-quoted bash string and a stray apostrophe will break the script.
if raw.startswith("ANALYSIS"):
    _, _, raw = raw.partition("\n")
    raw = raw.lstrip()

m = re.match(r"^\s*\[(\d+)\]\s*(.*)$", raw, re.DOTALL)
if not m:
    out = raw
else:
    score = int(m.group(1))
    body = m.group(2)
    head = f"{score_color(score)}[{score}]{RESET}"
    hint = ""
    hint_label = ""
    m_div = re.search(r"\n(─{2,}[^\n]*─{2,})\n", body)
    if m_div:
        hint_label = m_div.group(1).strip()
        hint = body[m_div.end():]
        body = body[:m_div.start()]
    else:
        m_div2 = re.match(r"^(─{2,}[^\n]*─{2,})\n", body)
        if m_div2:
            hint_label = m_div2.group(1).strip()
            hint = body[m_div2.end():]
            body = ""
    # Skip diff when score is 0 — the original was a different language, so
    # every token is "changed" and the highlight is just noise. Color the
    # whole rewrite green (per-token, so terminal wrap does not drop ANSI)
    # since semantically every word is an "addition" vs. the original.
    if score == 0 or not body.strip():
        if score == 0 and body.strip():
            colored = "".join(
                f"{ADDED}{tok}{RESET}" if tok.strip() else tok
                for tok in tokenize(body, language)
            )
            out = f"{head} {colored}".rstrip()
        else:
            out = f"{head} {body}".rstrip()
    else:
        # Render a single line (or the whole text) as a tokenized colored
        # diff. Whitespace tokens from `delete` blocks are dropped — emitting
        # them would carry original line breaks into the rewrite layout and
        # produce ghost newlines when SequenceMatcher aligned tokens across
        # line boundaries.
        def render(orig, new):
            orig_tokens = tokenize(orig, language)
            new_tokens = tokenize(new, language)
            sm = difflib.SequenceMatcher(a=orig_tokens, b=new_tokens, autojunk=False)
            parts = []
            for tag, i1, i2, j1, j2 in sm.get_opcodes():
                if tag == "equal":
                    for tok in new_tokens[j1:j2]:
                        if tok.strip():
                            parts.append(f"{DEFAULT}{tok}{RESET}")
                        else:
                            parts.append(tok)
                elif tag == "delete":
                    for tok in orig_tokens[i1:i2]:
                        if tok.strip():
                            parts.append(f"{DELETE}{tok}{RESET}")
                elif tag == "insert":
                    for tok in new_tokens[j1:j2]:
                        if tok.strip():
                            parts.append(f"{ADDED}{tok}{RESET}")
                        else:
                            parts.append(tok)
                elif tag == "replace":
                    for tok in orig_tokens[i1:i2]:
                        if tok.strip():
                            parts.append(f"{DELETE}{tok}{RESET}")
                    for tok in new_tokens[j1:j2]:
                        if tok.strip():
                            parts.append(f"{ADDED}{tok}{RESET}")
                        else:
                            parts.append(tok)
            return "".join(parts)

        # Diff per line when the AI preserved the line structure. This stops
        # SequenceMatcher from aligning a token on line N of the original
        # with one on line M of the rewrite, which would otherwise produce
        # ghost line breaks in the displayed output.
        orig_lines = prompt.split("\n")
        new_lines = body.split("\n")
        if len(orig_lines) == len(new_lines) and len(orig_lines) > 1:
            joined = "\n".join(render(o, n) for o, n in zip(orig_lines, new_lines))
        else:
            joined = render(prompt, body)
        out = f"{head} {joined}"

    if hint:
        # Per-token color wrap (not whole-line wrap). The Claude Code
        # systemMessage renderer drops ANSI styling across terminal-wrap
        # boundaries, so a long single-line hint shows yellow only on the
        # first wrapped row. Wrapping every token individually means each
        # word carries its own color, and wrapping no longer breaks it —
        # the body diff above already relies on the same trick.
        def color_line(ln):
            if not ln:
                return ""
            return "".join(
                f"{HINT}{tok}{RESET}" if tok.strip() else tok
                for tok in tokenize(ln, language)
            )
        lines = []
        if hint_label:
            lines.append(color_line(hint_label))
        lines.extend(color_line(ln) for ln in hint.rstrip().split("\n"))
        out += "\n" + "\n".join(lines)

print(json.dumps({"systemMessage": "\n" + out}, ensure_ascii=False))
')"
log "emit json[0..200]=$(printf '%s' "$OUTPUT_JSON" | head -c 200)"
printf '%s\n' "$OUTPUT_JSON"

exit 0
