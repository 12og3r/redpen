#!/usr/bin/env python3
"""
Render the coach output as a colored ANSI diff inside a JSON envelope.

Reads three env vars and prints the {"systemMessage": "..."} JSON to stdout.

Env:
  REWRITTEN        — raw stdout from the headless LLM call
  ORIGINAL_PROMPT  — the user's original prompt
  LT_LANGUAGE      — one of english | chinese | spanish | japanese
"""
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
            # Drop the divider label entirely; use a colored arrow as the
            # visual cue that what follows is the native-style version.
            sep = f"  {HINT}→{RESET}  "
            out += sep + " ".join(hint_body_lines)
        else:
            lines = []
            if hint_label:
                lines.append(color_line(hint_label))
            lines.extend(hint_body_lines)
            out += "\n" + "\n".join(lines)

print(json.dumps({"systemMessage": "\n" + out}, ensure_ascii=False))
