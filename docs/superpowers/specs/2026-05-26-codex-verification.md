# redpen-codex Verification Report

Date: 2026-05-26
Branch: feature/redpen-codex @ 4f46951a1dba01756cda36e42bb8d2de57145dd7
Codex CLI installed: NO (per Task 3 research)

---

## Verified on this machine

### 1. Structural checks — all 9 required files present

PASS: plugins/redpen-codex/.codex-plugin/plugin.json (677 bytes, exists)
PASS: plugins/redpen-codex/hooks/hooks.json (252 bytes, exists)
PASS: plugins/redpen-codex/hooks/grammar_check.sh (10477 bytes, exists)
PASS: plugins/redpen-codex/skills/setup/SKILL.md (5328 bytes, exists)
PASS: plugins/shared/coach_prompts.sh (19546 bytes, exists)
PASS: plugins/shared/render_diff.py (7314 bytes, exists)
PASS: .agents/plugins/marketplace.json (677 bytes, exists)
PASS: .claude-plugin/marketplace.json (549 bytes, exists)
PASS: README.md (13338 bytes, exists)

### 2. JSON parse — all 4 JSON files valid

PASS: plugins/redpen-codex/.codex-plugin/plugin.json
PASS: plugins/redpen-codex/hooks/hooks.json
PASS: .agents/plugins/marketplace.json
PASS: .claude-plugin/marketplace.json

### 3. Bash + Python syntax — all 4 files parse cleanly

PASS: plugins/redpen-codex/hooks/grammar_check.sh — bash -n clean
PASS: plugins/redpen/hooks/grammar_check.sh — bash -n clean
PASS: plugins/shared/coach_prompts.sh — bash -n clean
PASS: plugins/shared/render_diff.py — ast.parse clean

### 4. Executable bits — all scripts are +x

PASS: plugins/redpen-codex/hooks/grammar_check.sh is +x
PASS: plugins/redpen/hooks/grammar_check.sh is +x
PASS: plugins/shared/coach_prompts.sh is +x
PASS: plugins/shared/render_diff.py is +x

### 5. Claude Code regression (Tasks 1–2 harness)

PASS: Claude Code regression — zero diff vs baseline. Tasks 3–8 did not
break the existing Claude Code plugin. (Baseline survived a machine restart
because /tmp/redpen-baseline/run.sh and /tmp/redpen-baseline/before.txt were
present from Task 1.)

### 6. Codex hook end-to-end with mocked codex (9 samples)

A mock `codex` binary was placed on PATH, returning a fixed "[80] i want
to test the hook. / ──── Native style ──── / wanna test the hook?" response.
Each sample exercised a different code path through the hook.

PASS (sample 1): plain prose "i want test the hook" => systemMessage emitted.
  render_diff.py correctly color-coded word-level diff between original and
  rewrite.

PASS (sample 2): pure slash "/help" => empty output (skipped).
  Log confirmed: "skip: pure slash command".

PASS (sample 3): shell passthrough "!ls" => empty output (skipped).
  Log confirmed: "skip: shell passthrough".

PASS (sample 4): harness envelope "<system-reminder>noise</system-reminder>"
  => empty output (skipped).
  Log confirmed: "skip: harness-injected envelope".

PASS (sample 5): slash with args "/help me with this thing" => systemMessage
  emitted. Hook correctly stripped the "/help " prefix, coached only
  "me with this thing". render_diff.py diffed it against the mock rewrite.
  This is the intended behavior — only the user-typed prose is sent to the
  coach, not the slash command name.

PASS (sample 6): first-run (no ~/.codex/redpen.config) => additionalContext
  JSON emitted with hookEventName=UserPromptSubmit and
  "<redpen-codex-first-run>" envelope. Nudge fires correctly before any
  coaching attempt.

PASS (sample 7): long prompt (2001 chars, exceeds MAX_PROMPT_CHARS=2000) =>
  empty output (skipped). Log confirmed: "skip: prompt too long".

PASS (sample 8): recursion guard (REDPEN_ACTIVE=1) => empty output (skipped).
  Log confirmed: "skip: recursion guard". Prevents infinite loop when the
  hook's own `codex exec` invocation re-triggers the hook.

PASS (sample 9): empty prompt => empty output (skipped).
  Log confirmed: "skip: empty prompt".

### 7. Cross-file consistency — Claude Code hook vs Codex hook

PASS: Both hooks call set_coach_system_instr exactly once (count: 1 each).
PASS: Both hooks call render_diff.py exactly twice (count: 2 each — once in
  the assignment, once in a || error branch).
PASS: Both hooks set _REDPEN_SHARED_DIR using identical BASH_SOURCE-relative
  path resolution:
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" && pwd)"
  This resolves to plugins/shared/ for in-repo dev installs.

### 8. Codex plugin manifest fields

PASS: name = "redpen-codex"
PASS: version = "0.1.0"
PASS: paths.hooks = "./hooks/hooks.json"
PASS: paths.skills = "./skills"

### 9. hooks.json event wiring

PASS: hooks.json declares UserPromptSubmit event with a single command-type
  hook running:
    bash "${PLUGIN_ROOT}/hooks/grammar_check.sh"
  with timeout=60. Event name matches the Claude Code hook's event name.

### 10. Marketplace registration

PASS: .agents/plugins/marketplace.json contains a "redpen-codex" entry with:
  - source.source = "local"
  - source.path = "./plugins/redpen-codex"
  - policy.installation = "AVAILABLE"
  - policy.authentication = "ON_INSTALL"
  - category = "productivity"
NOTE: .claude-plugin/marketplace.json covers only the Claude Code plugin
  (redpen); that file has not been modified by the Codex work, which is
  correct.

### 11. SKILL.md frontmatter

PASS: plugins/redpen-codex/skills/setup/SKILL.md has valid YAML frontmatter
  with:
  - name: redpen-setup
  - description: (covers language, model, native-style hint config)
  - allowed-tools: Read, Write

### 12. README documentation

PASS: README.md mentions "redpen-codex" 4 times and includes Codex plugin
  install instructions.

---

## Summary: 12/12 check groups passed, 9/9 mock smoke tests passed.

All static/structural checks and all testable behavioral paths verified.

---

## Deferred to user (requires Codex CLI install)

The 8-step manual test plan from the spec
(docs/superpowers/specs/2026-05-26-redpen-codex-design.md, "Testing" section)
needs to be run on a machine with Codex CLI installed. Steps:

1. Install Codex CLI plugin from the local marketplace:
   ```
   codex plugin marketplace add /path/to/redpen
   codex plugin add redpen-codex
   ```

2. First-run nudge: delete ~/.codex/redpen.config, start codex, type any
   prompt. Expected: model offers to run $redpen-setup before answering.

3. English typo: type "i want test the hook".
   Expected: colored [NN] line under the prompt.

4. Chinese-in-English-mode: type "你好世界".
   Expected: [0] hello world (score 0 for foreign characters).

5. Slash skip: type /help.
   Expected: no coach output.

6. Shell skip: type !ls.
   Expected: no coach output.

7. Long-prompt skip: paste 3000+ chars.
   Expected: no coach output; log at ~/.codex/redpen.log says
   "skip: prompt too long".

8. Language switch: $redpen-setup → switch to Chinese → type a Chinese prompt
   with a typo. Expected: Chinese divider "──── 地道说法 ────" and Chinese
   colloquial rewrite.

---

## Known unknowns to validate during live testing

1. FLAG STACK COMPATIBILITY: Whether
     codex exec --ephemeral --ignore-user-config --ignore-rules \
       --skip-git-repo-check --sandbox read-only -c model_reasoning_effort=low
   actually combines without errors. This flag stack is from Task 3 research
   but was never live-tested with a real Codex binary.

2. CONFIG KEY SYNTAX: Whether `-c model_reasoning_effort=low` is the correct
   key name to suppress thinking tokens. Codex might use a different key name
   or not support this config key at all.

3. MODEL AVAILABILITY: Whether `gpt-4o-mini` is available on the user's
   OpenAI account. The fallback default in the hook is gpt-4o-mini; if the
   account restricts models, setup should pick an available one.

4. LATENCY FLOOR: The hook's headless `codex exec` call has unknown cold-start
   latency. The Claude Code version uses `claude -p` which is well-benchmarked;
   Codex's equivalent has not been measured. If p95 latency is >5s, revisit
   the flag stack (e.g., remove --sandbox if it adds significant overhead).

5. SHARED/ PATH RESOLUTION AT INSTALL TIME: The hook resolves plugins/shared/
   via ${BASH_SOURCE[0]}. This works for in-repo dev installs. Whether Codex's
   plugin installer preserves directory structure such that the relative path
   ../../shared still resolves correctly from the installed hook's location is
   unknown. If the installer flattens the tree, shared/ would need to be
   bundled inside plugins/redpen-codex/.

6. FIRST-RUN NUDGE BEHAVIOR: Whether the `additionalContext` injected via
   UserPromptSubmit hookSpecificOutput actually causes Codex to recognize and
   invoke the $redpen-setup skill. The format mirrors the Claude Code hook but
   Codex may parse or act on additionalContext differently.

7. TOOL INJECTION OVERHEAD: The hook comment notes Codex has no --no-tools
   analog, so ~11k tokens of tool definitions are always injected into the
   headless exec context. This inflates cost and latency vs. the Claude Code
   version. Measure and decide if mitigation is needed.

---

## Recommendations before publishing v0.1.0

1. Run manual steps 1–8 above on a machine with Codex CLI installed.
   File issues for any failures, especially around the flag stack (#1) and
   config key syntax (#2).

2. Bench cold-start latency for `codex exec` with the full flag stack.
   If p95 is >5s, profile which flags contribute most and consider removing
   non-critical ones (--ignore-rules, --skip-git-repo-check are likely cheap).

3. Verify plugin install path behavior (#5). If shared/ isn't installed
   alongside hooks/, either bundle it inside the plugin directory or document
   that the plugin is dev-install-only in v0.1.0.

4. If the first-run nudge (#6) doesn't work in live Codex, consider falling
   back to the plain-text systemMessage approach (emit a text message saying
   "run $redpen-setup to configure") instead of the additionalContext mechanism.

5. After live testing passes, bump README to v0.1.0 and tag the release.
