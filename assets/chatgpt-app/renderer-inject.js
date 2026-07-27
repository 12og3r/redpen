if (window.__REDPEN_CHATGPT_APP_RENDERER__) return;
window.__REDPEN_CHATGPT_APP_RENDERER__ = { version: "0.4.4" };

const bridge = window.__REDPEN_CHATGPT_APP__;
const pending = [];
const seenDomKeys = new Set();
const MAX_CACHED_FEEDBACK = 200;
const FEEDBACK_STORAGE_KEY = "redpen.chatgpt-app.feedback.v1";
const persistedFeedbackState = loadPersistedFeedbackState();
const feedbackByDomKey = new Map(persistedFeedbackState.feedback);
const inFlightByDomKey = new Map();
const retryableByDomKey = new Map([
  ...persistedFeedbackState.retryable,
  ...persistedFeedbackState.inFlight,
]);
const dismissedDomKeys = new Set(persistedFeedbackState.dismissed);
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
  scheduleScan();
}

function installStyles() {
  if (document.getElementById("redpen-chatgpt-app-style")) return;
  const style = document.createElement("style");
  style.id = "redpen-chatgpt-app-style";
  style.textContent = `
.redpen-feedback {
  --redpen-accent: oklch(0.58 0.2 25);
  --redpen-text: var(--color-token-text-primary, currentColor);
  --redpen-muted: var(
    --color-token-text-secondary,
    color-mix(in oklch, currentColor 62%, transparent)
  );
  --redpen-border: var(
    --color-token-border,
    color-mix(in oklch, currentColor 13%, transparent)
  );
  --redpen-hover: var(
    --color-background-elevated-secondary,
    color-mix(in oklch, currentColor 7%, transparent)
  );
  --redpen-insert: var(--color-text-success, oklch(0.55 0.14 145));
  --redpen-delete: var(--color-text-error, oklch(0.56 0.18 25));
  align-self: flex-end;
  box-sizing: border-box;
  inline-size: min(
    max(20rem, var(--redpen-anchor-width, 42rem)),
    calc(100% - 3rem)
  );
  max-inline-size: 42rem;
  margin-block-start: 0.375rem;
  padding-block: 0.5rem 0.25rem;
  border-block-start: 1px solid var(--redpen-border);
  background: transparent;
  color: var(--redpen-text);
  font: inherit;
  font-size: 0.875rem;
  line-height: 1.45;
  white-space: normal;
  container-type: inline-size;
}
.redpen-feedback * {
  box-sizing: border-box;
}
.redpen-feedback[hidden] {
  display: none !important;
}
.redpen-feedback-error {
  inline-size: min(
    max(24rem, var(--redpen-anchor-width, 42rem)),
    calc(100% - 3rem)
  );
}
.redpen-feedback[data-redpen-tone="dark"] {
  --redpen-accent: oklch(0.72 0.16 25);
  --redpen-insert: var(--color-text-success, oklch(0.76 0.13 145));
  --redpen-delete: var(--color-text-error, oklch(0.74 0.14 25));
}
.redpen-feedback-header {
  display: flex;
  align-items: center;
  gap: 0.375rem;
  min-block-size: 2rem;
  min-width: 0;
}
.redpen-feedback-mark {
  flex: none;
  color: var(--redpen-accent);
  font-size: 1rem;
  font-weight: 700;
  line-height: 1;
  transform: rotate(-8deg);
}
.redpen-feedback-title {
  flex: none;
  font-size: 0.8125rem;
  font-weight: 650;
  letter-spacing: -0.005em;
}
.redpen-feedback-separator,
.redpen-feedback-score,
.redpen-feedback-status {
  color: var(--redpen-muted);
  font-size: 0.75rem;
}
.redpen-feedback-score.high {
  color: var(--redpen-insert);
}
.redpen-feedback-score {
  font-variant-numeric: tabular-nums;
}
.redpen-feedback-status {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.redpen-feedback-score,
.redpen-feedback-actions {
  flex: none;
}
.redpen-feedback-actions {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 0.125rem;
}
.redpen-action {
  position: relative;
  display: inline-grid;
  min-inline-size: 2rem;
  min-block-size: 2rem;
  place-items: center;
  padding: 0.375rem;
  border: 0;
  border-radius: 0.5rem;
  background: transparent;
  color: inherit;
  cursor: pointer;
  font: inherit;
  font-size: 0.75rem;
  line-height: 1;
  opacity: 0.68;
  transition:
    background-color 140ms cubic-bezier(0.25, 1, 0.5, 1),
    color 140ms cubic-bezier(0.25, 1, 0.5, 1),
    opacity 140ms cubic-bezier(0.25, 1, 0.5, 1),
    transform 100ms cubic-bezier(0.25, 1, 0.5, 1);
}
.redpen-action:hover {
  background: var(--redpen-hover);
  opacity: 1;
}
.redpen-action:active {
  transform: scale(0.94);
}
.redpen-action:focus-visible,
.redpen-native-summary:focus-visible {
  outline: 2px solid var(--redpen-accent);
  outline-offset: 2px;
}
.redpen-action.success {
  color: var(--redpen-insert);
  opacity: 1;
}
.redpen-action-glyph {
  font-size: 1rem;
  line-height: 1;
}
.redpen-action-text {
  padding-inline: 0.625rem;
}
.redpen-feedback-body {
  max-block-size: 12rem;
  margin-block: 0.25rem 0.125rem;
  overflow: auto;
  overflow-wrap: anywhere;
  white-space: pre-wrap;
  font-size: 0.875rem;
  line-height: 1.5;
  text-wrap: pretty;
}
.redpen-feedback.is-translation .redpen-feedback-body {
  font-weight: 520;
}
.redpen-diff-insert {
  color: var(--redpen-insert);
  font-weight: 620;
  text-decoration: underline;
  text-decoration-color: color-mix(
    in oklch,
    var(--redpen-insert) 42%,
    transparent
  );
  text-decoration-thickness: 0.08em;
  text-underline-offset: 0.16em;
}
.redpen-diff-delete {
  color: var(--redpen-delete);
  text-decoration-line: line-through;
  text-decoration-thickness: 0.09em;
  text-decoration-color: currentColor;
}
.redpen-diff-delete + .redpen-diff-insert {
  margin-inline-start: 0.12em;
}
.redpen-native {
  margin-block-start: 0.125rem;
}
.redpen-native-summary {
  display: flex;
  min-block-size: 2.25rem;
  align-items: center;
  gap: 0.375rem;
  width: fit-content;
  border-radius: 0.375rem;
  color: var(--redpen-muted);
  cursor: pointer;
  font-size: 0.75rem;
  font-weight: 560;
  list-style: none;
}
.redpen-native-summary::-webkit-details-marker {
  display: none;
}
.redpen-native-summary::before {
  content: "›";
  display: inline-block;
  color: var(--redpen-accent);
  font-size: 1rem;
  line-height: 1;
  transition: transform 160ms cubic-bezier(0.25, 1, 0.5, 1);
}
.redpen-native[open] > .redpen-native-summary::before {
  transform: rotate(90deg);
}
.redpen-feedback-native {
  max-block-size: 10rem;
  padding: 0 0 0.5rem 1.125rem;
  overflow: auto;
  overflow-wrap: anywhere;
  color: var(--redpen-muted);
  font-size: 0.8125rem;
  line-height: 1.5;
  white-space: pre-wrap;
}
.redpen-feedback-loading,
.redpen-feedback-error {
  color: var(--redpen-muted);
}
.redpen-loading-placeholder {
  display: grid;
  gap: 0.375rem;
  padding-block: 0.25rem 0.375rem;
}
.redpen-loading-line {
  block-size: 0.5rem;
  border-radius: 999px;
  background: var(--redpen-border);
  animation: redpen-pulse 1.4s cubic-bezier(0.65, 0, 0.35, 1) infinite;
}
.redpen-loading-line:last-child {
  inline-size: 62%;
}
.redpen-feedback-ready {
  animation: redpen-reveal 160ms cubic-bezier(0.16, 1, 0.3, 1) both;
}
@keyframes redpen-pulse {
  0%, 100% {
    opacity: 0.42;
  }
  50% {
    opacity: 0.9;
  }
}
@keyframes redpen-reveal {
  from {
    opacity: 0;
    transform: translateY(2px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
.redpen-sr-only {
  position: absolute !important;
  width: 1px !important;
  height: 1px !important;
  padding: 0 !important;
  margin: -1px !important;
  overflow: hidden !important;
  clip: rect(0, 0, 0, 0) !important;
  white-space: nowrap !important;
  border: 0 !important;
}
@media (pointer: coarse) {
  .redpen-action {
    min-inline-size: 2.75rem;
    min-block-size: 2.75rem;
  }
  .redpen-native-summary {
    min-block-size: 2.75rem;
  }
}
@media (prefers-reduced-motion: reduce) {
  .redpen-feedback-ready,
  .redpen-loading-line {
    animation: none;
  }
  .redpen-action,
  .redpen-native-summary::before {
    transition: none;
  }
}
@media (forced-colors: active) {
  .redpen-feedback {
    border-block-start-color: CanvasText;
  }
  .redpen-action:focus-visible,
  .redpen-native-summary:focus-visible {
    outline-color: Highlight;
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
  const entries = userBubbleEntries();
  restoreFeedback(entries);
  if (!pending.length) return;

  for (const { bubble, text, domKey } of entries) {
    if (seenDomKeys.has(domKey) || hasFeedbackForDomKey(bubble, domKey)) {
      continue;
    }

    const idx = pending.findIndex((item) => promptMatchesBubble(item, text));
    if (idx < 0) continue;

    const item = pending.splice(idx, 1)[0];
    seenDomKeys.add(domKey);
    bubble.dataset.redpenChatgptAppProcessed = item.id;

    const block = baseBlock();
    block.hidden = true;
    block.dataset.domKey = domKey;
    attachFeedbackBlock(bubble, block);
    runRedpen(item, block);
  }
}

function userBubbleEntries() {
  const counts = new Map();
  const entries = [];
  for (const bubble of userBubbles()) {
    const text = bubbleText(bubble);
    if (!text) continue;
    const occurrence = (counts.get(text) || 0) + 1;
    counts.set(text, occurrence);
    entries.push({
      bubble,
      text,
      domKey: `${conversationKey()}|${hashText(text)}|${occurrence}`,
    });
  }
  return entries;
}

function conversationKey() {
  const activeThread = document.querySelector(
    '[data-app-action-sidebar-thread-active="true"][data-app-action-sidebar-thread-id]',
  );
  const threadId = activeThread?.getAttribute(
    "data-app-action-sidebar-thread-id",
  );
  return threadId || `${location.pathname}${location.search}${location.hash}`;
}

function restoreFeedback(entries) {
  for (const { bubble, domKey } of entries) {
    const response = feedbackByDomKey.get(domKey);
    if (
      dismissedDomKeys.has(domKey) ||
      hasFeedbackForDomKey(bubble, domKey)
    ) {
      continue;
    }
    const inFlight = inFlightByDomKey.has(domKey);
    const retryableItem = retryableByDomKey.get(domKey);
    if (!response && !inFlight && !retryableItem) continue;

    const block = baseBlock();
    block.dataset.domKey = domKey;
    if (response) {
      renderFeedbackBlock(response, block);
    } else if (retryableItem) {
      renderErrorBlock(
        block,
        new Error("Analysis was interrupted when the application closed."),
        () => runRedpen(retryableItem, block),
        "Analysis interrupted",
      );
    } else {
      renderLoadingBlock(block);
    }
    attachFeedbackBlock(bubble, block);
    seenDomKeys.add(domKey);
  }
}

function rememberFeedback(domKey, response) {
  if (!domKey) return;
  feedbackByDomKey.delete(domKey);
  feedbackByDomKey.set(domKey, response);
  while (feedbackByDomKey.size > MAX_CACHED_FEEDBACK) {
    const oldestKey = feedbackByDomKey.keys().next().value;
    feedbackByDomKey.delete(oldestKey);
    dismissedDomKeys.delete(oldestKey);
  }
  persistFeedbackState();
}

function loadPersistedFeedbackState() {
  try {
    const parsed = JSON.parse(localStorage.getItem(FEEDBACK_STORAGE_KEY) || "{}");
    const feedback = Array.isArray(parsed.feedback)
      ? parsed.feedback
          .filter(
            (entry) =>
              Array.isArray(entry) &&
              entry.length === 2 &&
              typeof entry[0] === "string" &&
              entry[1] &&
              typeof entry[1] === "object",
          )
          .slice(-MAX_CACHED_FEEDBACK)
      : [];
    const retryable = loadPersistedRequests(parsed.retryable);
    const inFlight = loadPersistedRequests(parsed.inFlight);
    const persistedKeys = new Set([
      ...feedback.map(([domKey]) => domKey),
      ...retryable.map(([domKey]) => domKey),
      ...inFlight.map(([domKey]) => domKey),
    ]);
    const dismissed = Array.isArray(parsed.dismissed)
      ? parsed.dismissed.filter(
          (domKey) => typeof domKey === "string" && persistedKeys.has(domKey),
        )
      : [];
    return { feedback, dismissed, retryable, inFlight };
  } catch (_error) {
    return { feedback: [], dismissed: [], retryable: [], inFlight: [] };
  }
}

function loadPersistedRequests(value) {
  return Array.isArray(value)
    ? value.filter(
        (entry) =>
          Array.isArray(entry) &&
          entry.length === 2 &&
          typeof entry[0] === "string" &&
          entry[1] &&
          typeof entry[1] === "object" &&
          typeof entry[1].coachPrompt === "string",
      )
    : [];
}

function persistFeedbackState() {
  try {
    const dismissed = Array.from(dismissedDomKeys).filter(
      (domKey) =>
        feedbackByDomKey.has(domKey) ||
        retryableByDomKey.has(domKey) ||
        inFlightByDomKey.has(domKey),
    );
    localStorage.setItem(
      FEEDBACK_STORAGE_KEY,
      JSON.stringify({
        feedback: Array.from(feedbackByDomKey),
        dismissed,
        retryable: Array.from(retryableByDomKey),
        inFlight: Array.from(inFlightByDomKey, ([domKey, request]) => [
          domKey,
          request.item,
        ]),
      }),
    );
  } catch (_error) {
    // Persistence is best-effort: feedback must continue to work when storage
    // is unavailable or the host application's quota is exhausted.
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
  const bubbleWidth = Math.round(bubble.getBoundingClientRect().width);
  if (bubbleWidth > 0) {
    block.style.setProperty("--redpen-anchor-width", `${bubbleWidth}px`);
  }
  block.dataset.redpenTone = textColorIsLight(
    window.getComputedStyle(bubble).color,
  )
    ? "dark"
    : "light";
  bubble.insertAdjacentElement("afterend", block);
}

async function runRedpen(item, block) {
  const domKey = block.dataset.domKey;
  const request = { item };
  if (domKey) {
    retryableByDomKey.delete(domKey);
    inFlightByDomKey.set(domKey, request);
    dismissedDomKeys.delete(domKey);
    persistFeedbackState();
  }
  const loadingTimer = setTimeout(() => {
    for (const activeBlock of feedbackBlocksForDomKey(domKey, block)) {
      renderLoadingBlock(activeBlock);
    }
  }, 250);

  try {
    if (!bridge || typeof bridge.request !== "function") {
      throw new Error("redpen bridge is unavailable");
    }
    const response = await bridge.request("/coach", {
      prompt: item.coachPrompt,
      requestId: item.id,
    });
    clearTimeout(loadingTimer);
    if (!response || response.status === "skipped") {
      if (domKey && inFlightByDomKey.get(domKey) === request) {
        inFlightByDomKey.delete(domKey);
      }
      if (domKey) retryableByDomKey.delete(domKey);
      persistFeedbackState();
      for (const activeBlock of feedbackBlocksForDomKey(domKey, block)) {
        activeBlock.remove();
      }
      return;
    }
    if (response.status !== "ok") {
      throw new Error(response.message || "redpen failed");
    }
    if (domKey && inFlightByDomKey.get(domKey) === request) {
      inFlightByDomKey.delete(domKey);
    }
    rememberFeedback(domKey, response);
    const activeBlocks = feedbackBlocksForDomKey(domKey, block);
    if (!activeBlocks.length) {
      scheduleScan();
      return;
    }
    for (const activeBlock of activeBlocks) {
      if (dismissedDomKeys.has(domKey)) {
        activeBlock.remove();
      } else {
        renderFeedbackBlock(response, activeBlock);
      }
    }
  } catch (error) {
    clearTimeout(loadingTimer);
    if (domKey && inFlightByDomKey.get(domKey) === request) {
      inFlightByDomKey.delete(domKey);
    }
    if (domKey) retryableByDomKey.set(domKey, item);
    persistFeedbackState();
    const activeBlocks = feedbackBlocksForDomKey(domKey, block);
    if (!activeBlocks.length) {
      requeueDetachedItem(item, block);
      return;
    }
    for (const activeBlock of activeBlocks) {
      renderErrorBlock(activeBlock, error, () => runRedpen(item, activeBlock));
    }
  }
}

function feedbackBlocksForDomKey(domKey, fallback) {
  if (!domKey) return fallback && fallback.isConnected ? [fallback] : [];
  return Array.from(document.querySelectorAll(".redpen-feedback")).filter(
    (candidate) => candidate.dataset.domKey === domKey,
  );
}

function requeueDetachedItem(item, block) {
  // Editing and resending a message replaces the conversation branch in the
  // desktop app. The first scan can see the transient user bubble just before
  // React replaces it, so keep the submission alive and attach it again once
  // the replacement bubble has settled.
  const domKey = block.dataset.domKey;
  if (domKey) seenDomKeys.delete(domKey);
  if (!pending.some((candidate) => candidate.id === item.id)) {
    item.at = Date.now();
    pending.unshift(item);
  }
  scheduleScan();
}

function renderLoadingBlock(block) {
  prepareBlock(block, "loading");
  block.setAttribute("aria-busy", "true");

  const actions = appendFeedbackHeader(block, "Checking wording…");
  actions.appendChild(
    makeActionButton("Dismiss feedback", "×", () => dismissFeedback(block)),
  );

  const placeholder = document.createElement("div");
  placeholder.className = "redpen-loading-placeholder";
  placeholder.setAttribute("aria-hidden", "true");
  for (let idx = 0; idx < 2; idx += 1) {
    const line = document.createElement("span");
    line.className = "redpen-loading-line";
    placeholder.appendChild(line);
  }
  block.appendChild(placeholder);
  return block;
}

function renderErrorBlock(
  block,
  error,
  retry,
  statusText = "Couldn’t check this prompt",
) {
  prepareBlock(block, "error");
  const actions = appendFeedbackHeader(block, statusText);
  actions.appendChild(makeTextAction("Retry", retry));
  actions.appendChild(
    makeActionButton("Dismiss feedback", "×", () => dismissFeedback(block)),
  );

  const announcement = document.createElement("span");
  announcement.className = "redpen-sr-only";
  announcement.setAttribute("role", "alert");
  announcement.textContent = `Redpen: ${statusText}. You can try again.`;
  announcement.title = String(
    error && error.message ? error.message : error || "",
  );
  block.appendChild(announcement);
  return block;
}

function renderFeedbackBlock(response, block = baseBlock()) {
  const mode = feedbackMode(response);
  prepareBlock(block, `ready is-${mode}`);

  const numericScore = Number(response.score);
  const scoreText =
    mode === "correction" && Number.isFinite(numericScore)
      ? `${numericScore}/100`
      : "";
  const actions = appendFeedbackHeader(
    block,
    feedbackStatus(mode, response.language),
    scoreText,
    scoreClass(numericScore),
  );

  if (mode !== "unchanged" && String(response.rewrite || "").trim()) {
    const copy = makeActionButton("Copy suggestion", "⧉", async () => {
      await copyText(String(response.rewrite || ""));
      copy.classList.add("success");
      copy.setAttribute("aria-label", "Suggestion copied");
      copy.title = "Suggestion copied";
      copy.querySelector(".redpen-action-glyph").textContent = "✓";
      setTimeout(() => {
        copy.classList.remove("success");
        copy.setAttribute("aria-label", "Copy suggestion");
        copy.title = "Copy suggestion";
        copy.querySelector(".redpen-action-glyph").textContent = "⧉";
      }, 1400);
    });
    actions.appendChild(copy);
  }

  actions.appendChild(
    makeActionButton("Dismiss feedback", "×", () => dismissFeedback(block)),
  );

  if (mode !== "unchanged") {
    block.appendChild(renderSuggestion(response, mode));
  }

  if (response.nativeStyle) {
    block.appendChild(renderNativeStyle(response.nativeStyle));
  }

  return block;
}

function baseBlock() {
  const block = document.createElement("section");
  block.className = "redpen-feedback";
  block.setAttribute("data-redpen-feedback", "true");
  block.setAttribute("aria-label", "Redpen writing feedback");
  block.setAttribute("aria-live", "polite");
  block.setAttribute("aria-atomic", "false");
  return block;
}

function dismissFeedback(block) {
  const domKey = block.dataset.domKey;
  if (domKey) {
    dismissedDomKeys.add(domKey);
    persistFeedbackState();
  }
  block.remove();
}

function prepareBlock(block, stateClasses) {
  block.hidden = false;
  block.className = `redpen-feedback redpen-feedback-${stateClasses}`;
  block.removeAttribute("aria-busy");
  block.replaceChildren();
}

function appendFeedbackHeader(
  block,
  statusText,
  scoreText = "",
  scoreBand = "",
) {
  const header = document.createElement("div");
  header.className = "redpen-feedback-header";

  const mark = document.createElement("span");
  mark.className = "redpen-feedback-mark";
  mark.setAttribute("aria-hidden", "true");
  mark.textContent = "✎";
  header.appendChild(mark);

  const title = document.createElement("span");
  title.className = "redpen-feedback-title";
  title.textContent = "redpen";
  header.appendChild(title);

  const separator = document.createElement("span");
  separator.className = "redpen-feedback-separator";
  separator.setAttribute("aria-hidden", "true");
  separator.textContent = "·";
  header.appendChild(separator);

  const status = document.createElement("span");
  status.className = "redpen-feedback-status";
  status.textContent = statusText;
  status.title = statusText;
  header.appendChild(status);

  if (scoreText) {
    const score = document.createElement("span");
    score.className = `redpen-feedback-score ${scoreBand}`;
    score.textContent = scoreText;
    header.appendChild(score);
  }

  const actions = document.createElement("div");
  actions.className = "redpen-feedback-actions";
  header.appendChild(actions);
  block.appendChild(header);
  return actions;
}

function makeActionButton(label, glyph, onClick) {
  const button = document.createElement("button");
  button.className = "redpen-action";
  button.type = "button";
  button.setAttribute("aria-label", label);
  button.title = label;

  const visual = document.createElement("span");
  visual.className = "redpen-action-glyph";
  visual.setAttribute("aria-hidden", "true");
  visual.textContent = glyph;
  button.appendChild(visual);
  button.addEventListener("click", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    await onClick();
  });
  return button;
}

function makeTextAction(label, onClick) {
  const button = makeActionButton(label, "", onClick);
  button.classList.add("redpen-action-text");
  button.querySelector(".redpen-action-glyph").textContent = label;
  return button;
}

function renderSuggestion(response, mode) {
  const body = document.createElement("div");
  body.className = "redpen-feedback-body";
  body.dir = "auto";

  const segments = Array.isArray(response.diff) ? response.diff : [];
  if (mode === "correction" && segments.length) {
    for (const segment of segments) {
      const kind = ["insert", "delete", "equal"].includes(segment.kind)
        ? segment.kind
        : "equal";
      const element = document.createElement(
        kind === "insert" ? "ins" : kind === "delete" ? "del" : "span",
      );
      element.className = `redpen-diff-${kind}`;
      element.textContent = String(segment.text || "");
      if (kind === "insert") {
        element.setAttribute(
          "aria-label",
          `Inserted: ${String(segment.text || "")}`,
        );
      } else if (kind === "delete") {
        element.setAttribute(
          "aria-label",
          `Removed: ${String(segment.text || "")}`,
        );
      }
      body.appendChild(element);
    }
  } else {
    body.textContent = String(response.rewrite || "");
  }
  return body;
}

function renderNativeStyle(text) {
  const details = document.createElement("details");
  details.className = "redpen-native";

  const summary = document.createElement("summary");
  summary.className = "redpen-native-summary";
  summary.textContent = "More natural";
  details.appendChild(summary);

  const native = document.createElement("div");
  native.className = "redpen-feedback-native";
  native.dir = "auto";
  native.textContent = String(text);
  details.appendChild(native);
  return details;
}

function feedbackMode(response) {
  if (["translation", "correction", "unchanged"].includes(response.mode)) {
    return response.mode;
  }
  const score = Number(response.score);
  if (score === 0) return "translation";
  if (score >= 100) return "unchanged";
  return "correction";
}

function feedbackStatus(mode, language) {
  if (mode === "translation") {
    return `Translated to ${languageName(language)}`;
  }
  if (mode === "unchanged") return "Looks natural";
  return "Suggested edit";
}

function languageName(language) {
  const names = {
    english: "English",
    chinese: "Chinese",
    spanish: "Spanish",
    japanese: "Japanese",
  };
  return names[String(language || "").toLowerCase()] || "your target language";
}

function scoreClass(score) {
  if (score >= 80) return "high";
  if (score >= 50) return "mid";
  return "low";
}

function textColorIsLight(value) {
  const match = String(value || "").match(
    /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/,
  );
  if (!match) return false;
  const [, red, green, blue] = match.map(Number);
  return red * 0.299 + green * 0.587 + blue * 0.114 > 160;
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
