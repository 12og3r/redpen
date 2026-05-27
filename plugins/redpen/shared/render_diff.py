#!/usr/bin/env python3
"""
Render the coach output as a colored ANSI diff inside a JSON envelope.

Reads three env vars and prints the {"systemMessage": "..."} JSON to stdout.

Env:
  REWRITTEN        — raw stdout from the headless LLM call
  ORIGINAL_PROMPT  — the user's original prompt
  LT_LANGUAGE      — one of english | chinese | spanish | japanese
  REDPEN_OUTPUT    — "structured" to print UI-friendly JSON instead of systemMessage
"""
import json, os, re, difflib, struct

ANSI_RE = re.compile(r"\033\[[0-9;]*m")

def visual_width(s):
    plain = ANSI_RE.sub("", s)
    n = 0
    for ch in plain:
        if ("一" <= ch <= "鿿"
                or "　" <= ch <= "〿"
                or "぀" <= ch <= "ヿ"
                or "＀" <= ch <= "￯"):
            n += 2
        else:
            n += 1
    return n

def terminal_width(default=80):
    # Prefer the caller-provided COLUMNS — the bash hook detects the real
    # terminal width via `stty size </dev/tty` and exports it, which is the
    # only source that survives Codex's TTY-less hook spawn context.
    env_cols = os.environ.get("COLUMNS", "").strip()
    if env_cols.isdigit():
        n = int(env_cols)
        if n > 0:
            return n
    try:
        import fcntl, termios
        with open("/dev/tty", "rb") as tty:
            packed = fcntl.ioctl(tty.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
            _, cols, _, _ = struct.unpack("hhhh", packed)
            return cols if cols > 0 else default
    except Exception:
        return default

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

def append_segment(segments, kind, text):
    if not text:
        return
    if segments and segments[-1]["kind"] == kind:
        segments[-1]["text"] += text
    else:
        segments.append({"kind": kind, "text": text})

def diff_segments(orig, new, lang):
    orig_tokens = tokenize(orig, lang)
    new_tokens = tokenize(new, lang)
    sm = difflib.SequenceMatcher(a=orig_tokens, b=new_tokens, autojunk=False)
    segments = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            append_segment(segments, "equal", "".join(new_tokens[j1:j2]))
        elif tag == "delete":
            for tok in orig_tokens[i1:i2]:
                if tok.strip():
                    append_segment(segments, "delete", tok)
        elif tag == "insert":
            append_segment(segments, "insert", "".join(new_tokens[j1:j2]))
        elif tag == "replace":
            for tok in orig_tokens[i1:i2]:
                if tok.strip():
                    append_segment(segments, "delete", tok)
            append_segment(segments, "insert", "".join(new_tokens[j1:j2]))
    return segments

def structured_diff(prompt, body, score, lang):
    if not body:
        return []
    if score == 0:
        return [{"kind": "insert", "text": body}]
    orig_lines = prompt.split("\n")
    new_lines = body.split("\n")
    if len(orig_lines) == len(new_lines) and len(orig_lines) > 1:
        segments = []
        for idx, (orig, new) in enumerate(zip(orig_lines, new_lines)):
            if idx:
                append_segment(segments, "equal", "\n")
            for segment in diff_segments(orig, new, lang):
                append_segment(segments, segment["kind"], segment["text"])
        return segments
    return diff_segments(prompt, body, lang)

raw = os.environ.get("REWRITTEN", "")
prompt = os.environ.get("ORIGINAL_PROMPT", "")
language = os.environ.get("LT_LANGUAGE", "english")

# Haiku-only: model emits a leading "ANALYSIS: ..." line before the score
# (see IS_HAIKU block in grammar_check.sh) to prevent misjudging clean
# English as score 0. The user does not need to see it — strip it before
# rendering.
if raw.startswith("ANALYSIS:"):
    _, _, raw = raw.partition("\n")
    raw = raw.lstrip()

m = re.match(r"^\s*\[(\d+)\]\s*(.*)$", raw, re.DOTALL)
if not m:
    # Model failed to follow the [N] xxx format — usually a Haiku refusal.
    # Treat as score 0 and prepend the score so the existing score-0
    # rendering path (which colors the body green) takes over.
    raw = f"[0] {raw}"
    m = re.match(r"^\s*\[(\d+)\]\s*(.*)$", raw, re.DOTALL)
if m:
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
    if os.environ.get("REDPEN_OUTPUT", "").strip().lower() == "structured":
        print(json.dumps({
            "status": "ok",
            "score": score,
            "language": language,
            "rewrite": body.rstrip(),
            "nativeStyleLabel": hint_label,
            "nativeStyle": hint.rstrip(),
            "diff": structured_diff(prompt, body.rstrip(), score, language),
        }, ensure_ascii=False))
        raise SystemExit
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
        # Layout: Codex's systemMessage renderer collapses to a single-line
        # toast (prefixed "warning:") that strips all newlines including
        # \n\n. So we need a single-line shape there. Claude Code's
        # systemMessage renders honest multi-line — keep the rich layout
        # there. Toggle via REDPEN_SINGLE_LINE env var (default = multi).
        single_line = os.environ.get("REDPEN_SINGLE_LINE", "") in ("1", "true", "yes", "on")
        hint_body_lines = [color_line(ln) for ln in hint.rstrip().split("\n")]
        if single_line:
            # Codex's systemMessage toast strips literal `\n` (verified
            # 2026-05) but preserves runs of spaces. We synthesize a 3-row
            # layout — body / divider / native style — by padding each
            # segment to end-of-row, letting natural terminal wrap break
            # to the next visual row. The `warning:` prefix is wiped via
            # `\r\033[2K` at print time (see end of file), so each row
            # carries a 2-space left indent we manage ourselves.
            INDENT_COLS = 2
            INDENT = " " * INDENT_COLS
            term_cols = terminal_width()

            def pad_to_row_end(visible_col):
                return (term_cols - visible_col) if visible_col > 0 else 0

            # Body may contain literal `\n` when the user's prompt was
            # multi-line — the diff renderer preserves the original line
            # structure. Codex's toast strips those `\n` directly, which
            # would collapse the body into one visual row. Synthesize the
            # line breaks via pad-to-row-end + INDENT, same trick used
            # for the divider / native-style rows below.
            body_lines = out.split("\n")
            out = INDENT + body_lines[0]
            for line in body_lines[1:]:
                cur_col = visual_width(out) % term_cols
                out += (" " * pad_to_row_end(cur_col)) + INDENT + line

            # Last body row → divider row: fill last body row to its end
            # + INDENT on the divider row.
            cur_col = visual_width(out) % term_cols
            pad1 = pad_to_row_end(cur_col) + INDENT_COLS

            divider_str = color_line(hint_label) if hint_label else ""
            divider_visible = visual_width(hint_label) if hint_label else 0

            # Row 2 → Row 3: fill row 2 to its end + INDENT on row 3.
            cur_col_after_div = (INDENT_COLS + divider_visible) % term_cols
            pad2 = pad_to_row_end(cur_col_after_div) + INDENT_COLS

            # Hint may itself span multiple lines when the model decides
            # the native-style rephrasing reads better split. Each hint
            # line gets its own visual row via the same pad-to-row-end
            # + INDENT trick used for the body above.
            hint_lines_raw = [ln for ln in hint.rstrip().split("\n")]

            if divider_str:
                out += (" " * pad1) + divider_str
            # If there is no divider, the first hint line transitions
            # directly from the body — pad1 was already computed for that.
            first_pad = pad2 if divider_str else pad1

            for idx, ln in enumerate(hint_lines_raw):
                colored = color_line(ln)
                if idx == 0:
                    out += (" " * first_pad) + colored
                else:
                    cur_col = visual_width(out) % term_cols
                    out += (" " * pad_to_row_end(cur_col)) + INDENT + colored
        else:
            lines = []
            if hint_label:
                lines.append(color_line(hint_label))
            lines.extend(hint_body_lines)
            out += "\n" + "\n".join(lines)

# Experimental: try to wipe Codex's "warning: " prefix when in single-line
# (Codex) mode. \r returns to col 0, ESC[2K erases the current line. If
# Codex's TUI passes these through to the terminal, the prefix gets
# overwritten. If it filters them, no visible change.
single_line_mode = os.environ.get("REDPEN_SINGLE_LINE", "") in ("1", "true", "yes", "on")
prefix_wipe = "\r\033[2K" if single_line_mode else ""
print(json.dumps({"systemMessage": prefix_wipe + "\n" + out}, ensure_ascii=False))
