if (window.__REDPEN_CODEX_APP_RENDERER__) return;
window.__REDPEN_CODEX_APP_RENDERER__ = { version: "0.1.0" };

const bridge = window.__REDPEN_CODEX_APP__;
const pending = [];
const seenDomKeys = new Set();
let sequence = 0;
let scanTimer = 0;

const EDITOR_SELECTOR = [
  "textarea",
  '[contenteditable="true"]',
  '[contenteditable=""]',
  '[role="textbox"]',
].join(",");

function startWhenReady() {
  if (!document.body) {
    setTimeout(startWhenReady, 50);
    return;
  }
  installStyles();
  installCaptureListeners();
  new MutationObserver(scheduleScan).observe(document.body, {
    childList: true,
    subtree: true,
  });
  setInterval(prunePending, 5000);
}

function installStyles() {
  if (document.getElementById("redpen-codex-app-style")) return;
  const style = document.createElement("style");
  style.id = "redpen-codex-app-style";
  style.textContent = `
.redpen-feedback {
  align-self: flex-end;
  box-sizing: border-box;
  max-width: min(760px, calc(100% - 48px));
  margin-top: 6px;
  padding: 9px 10px;
  border: 1px solid rgba(24, 24, 27, 0.16);
  border-radius: 8px;
  background: rgba(250, 250, 250, 0.98);
  color: #18181b;
  box-shadow: 0 8px 24px rgba(15, 23, 42, 0.08);
  font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  white-space: normal;
}
.redpen-feedback * {
  box-sizing: border-box;
}
.redpen-feedback-header {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.redpen-feedback-title {
  font-weight: 650;
}
.redpen-feedback-score {
  border-radius: 999px;
  padding: 1px 7px;
  background: #e4e4e7;
  color: #27272a;
  font-size: 12px;
  font-weight: 650;
}
.redpen-feedback-score.high {
  background: #dcfce7;
  color: #166534;
}
.redpen-feedback-score.mid {
  background: #fef3c7;
  color: #92400e;
}
.redpen-feedback-score.low {
  background: #fee2e2;
  color: #991b1b;
}
.redpen-copy {
  margin-left: auto;
  border: 1px solid rgba(24, 24, 27, 0.18);
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.8);
  color: inherit;
  cursor: pointer;
  font: inherit;
  font-size: 12px;
  line-height: 1;
  padding: 5px 8px;
}
.redpen-copy:hover {
  background: rgba(244, 244, 245, 0.95);
}
.redpen-feedback-body {
  margin-top: 7px;
  white-space: pre-wrap;
  word-break: break-word;
}
.redpen-feedback-native {
  margin-top: 8px;
  border-top: 1px solid rgba(24, 24, 27, 0.12);
  padding-top: 7px;
  color: #3f3f46;
  white-space: pre-wrap;
  word-break: break-word;
}
.redpen-feedback-native-label {
  display: block;
  margin-bottom: 3px;
  color: #71717a;
  font-size: 12px;
  font-weight: 650;
}
.redpen-diff-insert {
  color: #15803d;
  font-weight: 650;
}
.redpen-diff-delete {
  color: #b91c1c;
  text-decoration: line-through;
  text-decoration-thickness: 1.5px;
}
.redpen-feedback-loading,
.redpen-feedback-error {
  color: #71717a;
}
@media (prefers-color-scheme: dark) {
  .redpen-feedback {
    border-color: rgba(244, 244, 245, 0.14);
    background: rgba(24, 24, 27, 0.98);
    color: #f4f4f5;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.24);
  }
  .redpen-feedback-score {
    background: #3f3f46;
    color: #fafafa;
  }
  .redpen-feedback-score.high {
    background: rgba(34, 197, 94, 0.18);
    color: #86efac;
  }
  .redpen-feedback-score.mid {
    background: rgba(245, 158, 11, 0.18);
    color: #fcd34d;
  }
  .redpen-feedback-score.low {
    background: rgba(239, 68, 68, 0.18);
    color: #fca5a5;
  }
  .redpen-copy {
    border-color: rgba(244, 244, 245, 0.18);
    background: rgba(39, 39, 42, 0.9);
  }
  .redpen-copy:hover {
    background: rgba(63, 63, 70, 0.95);
  }
  .redpen-feedback-native {
    border-top-color: rgba(244, 244, 245, 0.14);
    color: #d4d4d8;
  }
  .redpen-feedback-native-label,
  .redpen-feedback-loading,
  .redpen-feedback-error {
    color: #a1a1aa;
  }
  .redpen-diff-insert {
    color: #86efac;
  }
  .redpen-diff-delete {
    color: #fca5a5;
  }
}`;
  (document.head || document.documentElement).appendChild(style);
}

function installCaptureListeners() {
  document.addEventListener(
    "submit",
    () => captureSubmit(),
    true,
  );
  document.addEventListener(
    "keydown",
    (event) => {
      if (event.isComposing) return;
      const submits =
        event.key === "Enter" &&
        !event.shiftKey &&
        (event.metaKey || event.ctrlKey || isEditable(event.target));
      if (submits) captureSubmit();
    },
    true,
  );
  document.addEventListener(
    "pointerdown",
    (event) => {
      if (looksLikeSendButton(event.target)) captureSubmit();
    },
    true,
  );
}

function isEditable(target) {
  return Boolean(target && target.closest && target.closest(EDITOR_SELECTOR));
}

function looksLikeSendButton(target) {
  const button = target && target.closest && target.closest("button,[role='button']");
  if (!button || button.disabled || button.getAttribute("aria-disabled") === "true") {
    return false;
  }
  if (button.matches("button[type='submit']")) return true;
  const label = normalizeText(
    [
      button.getAttribute("aria-label"),
      button.getAttribute("title"),
      button.textContent,
    ].join(" "),
  ).toLowerCase();
  return /\b(send|submit)\b/.test(label) || label.includes("发送");
}

function captureSubmit() {
  const rawPrompt = readComposer();
  const coachPrompt = coachablePrompt(rawPrompt);
  if (!coachPrompt) return;

  const normalizedRaw = normalizeText(rawPrompt);
  const now = Date.now();
  const duplicate = pending.some(
    (item) => item.normalizedRaw === normalizedRaw && now - item.at < 1500,
  );
  if (duplicate) return;

  pending.push({
    id: `${now}-${++sequence}`,
    rawPrompt,
    coachPrompt,
    normalizedRaw,
    at: now,
  });
  prunePending();
  scheduleScan();
}

function readComposer() {
  const active = document.activeElement;
  const activeEditor =
    active && active.closest && active.closest(EDITOR_SELECTOR);
  if (activeEditor && isVisible(activeEditor)) {
    const activeText = editableText(activeEditor);
    if (normalizeText(activeText)) return activeText;
  }

  const editors = Array.from(document.querySelectorAll(EDITOR_SELECTOR))
    .filter(isVisible)
    .map((element) => ({
      element,
      text: editableText(element),
      area: element.getBoundingClientRect().width * element.getBoundingClientRect().height,
    }))
    .filter((item) => normalizeText(item.text));
  editors.sort((a, b) => b.area - a.area);
  return editors[0] ? editors[0].text : "";
}

function editableText(element) {
  if (!element) return "";
  if ("value" in element) return element.value || "";
  return element.innerText || element.textContent || "";
}

function coachablePrompt(raw) {
  let prompt = String(raw || "").trim();
  if (!prompt || prompt.length > 2000) return null;
  if (
    /^<(task-notification|system-reminder|command-name|command-message|command-args|local-command-stdout|local-command-stderr|bash-input|bash-stdout|bash-stderr|user-prompt-submit-hook)>/.test(
      prompt,
    )
  ) {
    return null;
  }
  if (prompt.startsWith("!")) return null;
  if (/^[/$]\S+$/.test(prompt)) return null;
  if (/^[/$]\S+\s+/.test(prompt)) {
    prompt = prompt.replace(/^[/$]\S+\s+/, "").trim();
  }
  return prompt || null;
}

function scheduleScan() {
  clearTimeout(scanTimer);
  scanTimer = setTimeout(scanForSubmittedMessages, 150);
}

function scanForSubmittedMessages() {
  prunePending();
  if (!pending.length) return;

  const counts = new Map();
  for (const bubble of userBubbles()) {
    const text = bubbleText(bubble);
    if (!text) continue;

    const occurrence = (counts.get(text) || 0) + 1;
    counts.set(text, occurrence);
    const domKey = `${location.pathname}|${hashText(text)}|${occurrence}`;
    if (seenDomKeys.has(domKey) || hasFeedbackForDomKey(bubble, domKey)) {
      continue;
    }

    const idx = pending.findIndex((item) => promptMatchesBubble(item, text));
    if (idx < 0) continue;

    const item = pending.splice(idx, 1)[0];
    seenDomKeys.add(domKey);
    bubble.dataset.redpenAppProcessed = item.id;

    const block = renderLoadingBlock();
    block.dataset.domKey = domKey;
    attachFeedbackBlock(bubble, block);
    runRedpen(item, block);
  }
}

function prunePending() {
  const cutoff = Date.now() - 120000;
  while (pending.length && pending[0].at < cutoff) {
    pending.shift();
  }
}

function userBubbles() {
  const root =
    document.querySelector(".thread-scroll-container, [data-testid='conversation'], main") ||
    document.body;
  const result = [];
  const seen = new Set();
  const push = (element) => {
    if (!element || seen.has(element) || !element.isConnected) return;
    if (element.closest && element.closest(".redpen-feedback")) return;
    seen.add(element);
    result.push(element);
  };

  root
    .querySelectorAll(
      [
        '[data-message-author-role="user"]',
        '[data-testid*="user"]',
        '[class*="user-message"]',
        '[class*="UserMessage"]',
      ].join(","),
    )
    .forEach(push);

  root
    .querySelectorAll(".group.flex.w-full.flex-col.items-end.justify-end.gap-1")
    .forEach((group) => {
      Array.from(group.children).forEach((child) => {
        const className = String(child.className || "");
        if (
          className.includes("bg-token-foreground/5") ||
          className.includes("rounded")
        ) {
          push(child);
        }
      });
      push(group);
    });

  return result.filter(isVisible).slice(-24);
}

function bubbleText(element) {
  const clone = element.cloneNode(true);
  clone
    .querySelectorAll(
      "button, svg, [aria-hidden='true'], .sr-only, .redpen-feedback",
    )
    .forEach((node) => node.remove());
  return normalizeText(clone.textContent);
}

function promptMatchesBubble(item, text) {
  if (text === item.normalizedRaw) return true;
  if (text.includes(item.normalizedRaw)) return true;
  if (item.normalizedRaw.includes(text) && text.length > 12) return true;
  return false;
}

function hasFeedbackForDomKey(bubble, domKey) {
  const parent = bubble.parentElement;
  if (!parent) return false;
  return Array.from(parent.querySelectorAll(".redpen-feedback")).some(
    (element) => element.dataset.domKey === domKey,
  );
}

function attachFeedbackBlock(bubble, block) {
  bubble.insertAdjacentElement("afterend", block);
}

async function runRedpen(item, block) {
  try {
    if (!bridge || typeof bridge.request !== "function") {
      throw new Error("redpen bridge is unavailable");
    }
    const response = await bridge.request("/coach", {
      prompt: item.coachPrompt,
      requestId: item.id,
    });
    if (!response || response.status === "skipped") {
      block.remove();
      return;
    }
    if (response.status !== "ok") {
      throw new Error(response.message || "redpen failed");
    }
    block.replaceWith(renderFeedbackBlock(response));
  } catch (error) {
    block.replaceWith(renderErrorBlock(error));
  }
}

function renderLoadingBlock() {
  const block = baseBlock();
  const body = document.createElement("div");
  body.className = "redpen-feedback-loading";
  body.textContent = "redpen checking...";
  block.appendChild(body);
  return block;
}

function renderErrorBlock(error) {
  const block = baseBlock();
  const body = document.createElement("div");
  body.className = "redpen-feedback-error";
  body.textContent = `redpen unavailable: ${error && error.message ? error.message : error}`;
  block.appendChild(body);
  return block;
}

function renderFeedbackBlock(response) {
  const block = baseBlock();

  const header = document.createElement("div");
  header.className = "redpen-feedback-header";

  const title = document.createElement("span");
  title.className = "redpen-feedback-title";
  title.textContent = "redpen";
  header.appendChild(title);

  if (Number.isFinite(Number(response.score))) {
    const score = document.createElement("span");
    score.className = `redpen-feedback-score ${scoreClass(Number(response.score))}`;
    score.textContent = String(response.score);
    header.appendChild(score);
  }

  const copy = document.createElement("button");
  copy.className = "redpen-copy";
  copy.type = "button";
  copy.textContent = "Copy";
  copy.addEventListener("click", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    await copyText(String(response.rewrite || ""));
    copy.textContent = "Copied";
    setTimeout(() => {
      copy.textContent = "Copy";
    }, 1400);
  });
  header.appendChild(copy);
  block.appendChild(header);

  const body = document.createElement("div");
  body.className = "redpen-feedback-body";
  const segments = Array.isArray(response.diff) ? response.diff : [];
  if (segments.length) {
    for (const segment of segments) {
      const span = document.createElement("span");
      span.className = `redpen-diff-${segment.kind || "equal"}`;
      span.textContent = String(segment.text || "");
      body.appendChild(span);
    }
  } else {
    body.textContent = String(response.rewrite || "");
  }
  block.appendChild(body);

  if (response.nativeStyle) {
    const native = document.createElement("div");
    native.className = "redpen-feedback-native";
    const label = document.createElement("span");
    label.className = "redpen-feedback-native-label";
    label.textContent = response.nativeStyleLabel || "Native style";
    native.appendChild(label);
    native.appendChild(document.createTextNode(String(response.nativeStyle)));
    block.appendChild(native);
  }

  return block;
}

function baseBlock() {
  const block = document.createElement("div");
  block.className = "redpen-feedback";
  block.setAttribute("data-redpen-feedback", "true");
  return block;
}

function scoreClass(score) {
  if (score >= 80) return "high";
  if (score >= 50) return "mid";
  return "low";
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch (_error) {
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.style.position = "fixed";
    textarea.style.left = "-9999px";
    document.body.appendChild(textarea);
    textarea.select();
    document.execCommand("copy");
    textarea.remove();
  }
}

function normalizeText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function hashText(value) {
  let hash = 0;
  const text = String(value || "");
  for (let i = 0; i < text.length; i += 1) {
    hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0;
  }
  return hash.toString(36);
}

function isVisible(element) {
  if (!element || !element.getBoundingClientRect) return false;
  const rect = element.getBoundingClientRect();
  const style = window.getComputedStyle(element);
  return (
    rect.width > 0 &&
    rect.height > 0 &&
    style.display !== "none" &&
    style.visibility !== "hidden"
  );
}

startWhenReady();
