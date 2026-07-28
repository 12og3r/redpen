if (window.__REDPEN_CHATGPT_APP_RENDERER__) return;
window.__REDPEN_CHATGPT_APP_RENDERER__ = { version: "0.4.4" };

const bridge = window.__REDPEN_CHATGPT_APP__;
const pending = [];
const seenDomKeys = new Set();
const MAX_CACHED_FEEDBACK = 200;
const CAPTURE_SETTLE_MS = 100;
const FEEDBACK_STORAGE_KEY = "redpen.chatgpt-app.feedback.v1";
const persistedFeedbackState = loadPersistedFeedbackState();
const sameBridgeInstance = Boolean(
  bridge?.instanceId &&
    persistedFeedbackState.bridgeInstanceId === bridge.instanceId,
);
const feedbackByDomKey = new Map(persistedFeedbackState.feedback);
const inFlightByDomKey = new Map();
const resumableByDomKey = new Map(
  sameBridgeInstance ? persistedFeedbackState.inFlight : [],
);
const retryableByDomKey = new Map(
  sameBridgeInstance
    ? persistedFeedbackState.retryable
    : [...persistedFeedbackState.retryable, ...persistedFeedbackState.inFlight].map(
        ([domKey, item]) => [domKey, withoutTransportId(item)],
      ),
);
const dismissedDomKeys = new Set(persistedFeedbackState.dismissed);
const checkedLegacyDomKeys = new Set();
let sequence = 0;
let scanTimer = 0;
let captureTimer = 0;
let stagedCapture = null;

const EDITOR_SELECTOR = [
  "textarea",
  '[contenteditable="true"]',
  '[contenteditable=""]',
  '[role="textbox"]',
].join(",");
const USER_MESSAGE_GROUP_SELECTOR =
  ".group.flex.w-full.flex-col.items-end.justify-end.gap-1";

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
  const capture = {
    rawPrompt,
    coachPrompt,
    normalizedRaw,
    at: now,
  };
  const mergedCapture = mergeSubmissionCapture(stagedCapture, capture);
  if (mergedCapture) {
    stagedCapture = mergedCapture;
  } else {
    flushStagedCapture();
    stagedCapture = capture;
  }
  clearTimeout(captureTimer);
  captureTimer = setTimeout(flushStagedCapture, CAPTURE_SETTLE_MS);
}

function mergeSubmissionCapture(current, candidate) {
  if (
    !current ||
    candidate.at - current.at > CAPTURE_SETTLE_MS ||
    !promptTextsAreVariants(current.normalizedRaw, candidate.normalizedRaw)
  ) {
    return null;
  }
  if (candidate.normalizedRaw.length <= current.normalizedRaw.length) {
    return current;
  }
  return { ...candidate, at: current.at };
}

function flushStagedCapture() {
  clearTimeout(captureTimer);
  captureTimer = 0;
  if (!stagedCapture) return;

  const capture = stagedCapture;
  stagedCapture = null;

  pending.push({
    id: `${capture.at}-${++sequence}`,
    ...capture,
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
  migrateLegacyTimestampState(entries);
  restoreFeedback(entries);
  if (!pending.length) return;

  for (const { bubble, anchor, text, domKey } of orderEntriesForPending(entries)) {
    if (seenDomKeys.has(domKey) || hasFeedbackForDomKey(anchor, domKey)) {
      continue;
    }

    const item = takePendingForBubble(text);
    if (!item) continue;
    seenDomKeys.add(domKey);
    bubble.dataset.redpenChatgptAppProcessed = item.id;

    const block = baseBlock();
    block.hidden = true;
    block.dataset.domKey = domKey;
    attachFeedbackBlock(bubble, anchor, block);
    runRedpen(item, block);
  }
}

function orderEntriesForPending(entries) {
  const newestFirst = [...entries].reverse();
  const exact = [];
  const fallback = [];
  for (const entry of newestFirst) {
    if (pending.some((item) => item.normalizedRaw === entry.text)) {
      exact.push(entry);
    } else {
      fallback.push(entry);
    }
  }
  return [...exact, ...fallback];
}

function userBubbleEntries() {
  const unique = [];
  for (const bubble of userBubbles()) {
    const text = bubbleText(bubble);
    if (!text) continue;
    collapseUserBubbleCandidate(unique, bubble, text);
  }

  const counts = new Map();
  const entries = [];
  const currentConversationKey = conversationKey();
  for (const { bubble, text } of unique) {
    const occurrence = (counts.get(text) || 0) + 1;
    counts.set(text, occurrence);
    entries.push({
      bubble,
      anchor: feedbackAnchorForBubble(bubble),
      conversationKey: currentConversationKey,
      occurrence,
      text,
      domKey: `${currentConversationKey}|${hashText(text)}|${occurrence}`,
    });
  }
  return entries;
}

function collapseUserBubbleCandidate(unique, bubble, text) {
  const nestedIndex = unique.findIndex(
    (entry) =>
      entry.text === text &&
      (entry.bubble.contains(bubble) || bubble.contains(entry.bubble)),
  );
  if (nestedIndex < 0) {
    unique.push({ bubble, text });
  } else if (unique[nestedIndex].bubble.contains(bubble)) {
    unique[nestedIndex] = { bubble, text };
  }
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

function migrateLegacyTimestampState(entries) {
  const persistedKeys = persistedDomKeys();
  if (!persistedKeys.size) return;

  let changed = false;
  for (const entry of entries) {
    if (
      checkedLegacyDomKeys.has(entry.domKey) ||
      persistedKeys.has(entry.domKey)
    ) {
      continue;
    }
    const legacyDomKey = findLegacyDomKey(entry, persistedKeys);
    if (!legacyDomKey) {
      checkedLegacyDomKeys.add(entry.domKey);
      continue;
    }
    if (inFlightByDomKey.has(legacyDomKey)) {
      seenDomKeys.add(entry.domKey);
      continue;
    }
    checkedLegacyDomKeys.add(entry.domKey);

    for (const stateMap of [
      feedbackByDomKey,
      retryableByDomKey,
      resumableByDomKey,
    ]) {
      if (!stateMap.has(legacyDomKey)) continue;
      stateMap.set(entry.domKey, stateMap.get(legacyDomKey));
      stateMap.delete(legacyDomKey);
    }
    if (dismissedDomKeys.delete(legacyDomKey)) {
      dismissedDomKeys.add(entry.domKey);
    }
    for (const block of document.querySelectorAll?.(".redpen-feedback") || []) {
      if (block.dataset.domKey === legacyDomKey) {
        block.dataset.domKey = entry.domKey;
      }
    }
    if (seenDomKeys.delete(legacyDomKey)) {
      seenDomKeys.add(entry.domKey);
    }
    persistedKeys.delete(legacyDomKey);
    persistedKeys.add(entry.domKey);
    changed = true;
  }
  if (changed) persistFeedbackState();
}

function persistedDomKeys() {
  return new Set([
    ...feedbackByDomKey.keys(),
    ...retryableByDomKey.keys(),
    ...inFlightByDomKey.keys(),
    ...resumableByDomKey.keys(),
  ]);
}

function findLegacyDomKey(entry, persistedKeys) {
  const occurrences =
    entry.occurrence === 1 ? [1] : [1, entry.occurrence];
  const legacyTexts =
    entry.legacyTexts || legacyBubbleTexts(entry.bubble, entry.text);
  for (const legacyText of legacyTexts) {
    const hash = hashText(legacyText);
    for (const occurrence of occurrences) {
      const candidate =
        `${entry.conversationKey}|${hash}|${occurrence}`;
      if (persistedKeys.has(candidate)) return candidate;
    }
  }
  return null;
}

function restoreFeedback(entries) {
  for (const { bubble, anchor, domKey } of entries) {
    const response = feedbackByDomKey.get(domKey);
    if (dismissedDomKeys.has(domKey)) {
      seenDomKeys.add(domKey);
      continue;
    }
    if (hasFeedbackForDomKey(anchor, domKey)) {
      seenDomKeys.add(domKey);
      continue;
    }
    const inFlight = inFlightByDomKey.has(domKey);
    const resumableItem = resumableByDomKey.get(domKey);
    const retryableItem = retryableByDomKey.get(domKey);
    if (!response && !inFlight && !resumableItem && !retryableItem) continue;

    const block = baseBlock();
    block.dataset.domKey = domKey;
    if (response) {
      renderFeedbackBlock(response, block);
    } else if (resumableItem) {
      renderLoadingBlock(block);
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
    attachFeedbackBlock(bubble, anchor, block);
    seenDomKeys.add(domKey);
    if (resumableItem) {
      resumableByDomKey.delete(domKey);
      runRedpen(resumableItem, block);
    }
  }
}

function rememberFeedback(domKey, response) {
  if (!domKey) return false;
  feedbackByDomKey.delete(domKey);
  feedbackByDomKey.set(domKey, response);
  while (feedbackByDomKey.size > MAX_CACHED_FEEDBACK) {
    const oldestKey = feedbackByDomKey.keys().next().value;
    feedbackByDomKey.delete(oldestKey);
    dismissedDomKeys.delete(oldestKey);
  }
  return persistFeedbackState();
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
    const bridgeInstanceId =
      typeof parsed.bridgeInstanceId === "string"
        ? parsed.bridgeInstanceId
        : null;
    return { feedback, dismissed, retryable, inFlight, bridgeInstanceId };
  } catch (_error) {
    return {
      feedback: [],
      dismissed: [],
      retryable: [],
      inFlight: [],
      bridgeInstanceId: null,
    };
  }
}

function withoutTransportId(item) {
  const copy = { ...item };
  delete copy.redpenRequestId;
  return copy;
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
        inFlightByDomKey.has(domKey) ||
        resumableByDomKey.has(domKey),
    );
    localStorage.setItem(
      FEEDBACK_STORAGE_KEY,
      JSON.stringify({
        bridgeInstanceId: bridge?.instanceId || null,
        feedback: Array.from(feedbackByDomKey),
        dismissed,
        retryable: Array.from(retryableByDomKey),
        inFlight: [
          ...Array.from(resumableByDomKey),
          ...Array.from(inFlightByDomKey, ([domKey, request]) => [
            domKey,
            request.item,
          ]),
        ],
      }),
    );
    return true;
  } catch (_error) {
    // Persistence is best-effort: feedback must continue to work when storage
    // is unavailable or the host application's quota is exhausted.
    return false;
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
    element = canonicalUserBubbleElement(element);
    if (!element || seen.has(element) || !element.isConnected) return;
    if (element.closest && element.closest(".redpen-feedback")) return;
    seen.add(element);
    result.push(element);
  };

  root
    .querySelectorAll(
      [
        '[data-message-author-role="user"]',
        '[data-user-message-bubble="true"]',
        '[data-testid*="user"]',
        '[class*="user-message"]',
        '[class*="UserMessage"]',
      ].join(","),
    )
    .forEach(push);

  root
    .querySelectorAll(USER_MESSAGE_GROUP_SELECTOR)
    .forEach((group) => {
      userMessageCandidatesForGroup(group).forEach(push);
    });

  return result.filter(isVisible).slice(-24);
}

function canonicalUserBubbleElement(element) {
  if (element?.matches?.('[data-user-message-bubble="true"]')) {
    return element;
  }
  return (
    element?.querySelector?.('[data-user-message-bubble="true"]') ||
    element?.closest?.('[data-user-message-bubble="true"]') ||
    element
  );
}

function isLikelyUserMessageChild(element) {
  const className = String(element?.className || "");
  return Boolean(
    element?.matches?.('[data-user-message-bubble="true"]') ||
      className.includes("bg-token-foreground/5") ||
      className.includes("rounded"),
  );
}

function userMessageCandidatesForGroup(group) {
  const stableBubble = group.querySelector?.(
    '[data-user-message-bubble="true"]',
  );
  if (stableBubble) return [stableBubble];
  const messageChildren = Array.from(group.children).filter(
    isLikelyUserMessageChild,
  );
  return messageChildren.length ? messageChildren : [group];
}

function feedbackAnchorForBubble(bubble) {
  const group = bubble.closest?.(USER_MESSAGE_GROUP_SELECTOR);
  if (group && bubble.parentElement !== group) return group;
  return bubble;
}

function legacyBubbleTexts(bubble, text) {
  const group = bubble.closest?.(USER_MESSAGE_GROUP_SELECTOR);
  if (!group || group === bubble) return [];
  const legacyText = bubbleText(group);
  return legacyText && legacyText !== text ? [legacyText] : [];
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
  if (text.startsWith(item.normalizedRaw)) return true;
  return false;
}

function promptTextsAreVariants(left, right) {
  if (!left || !right) return false;
  return left.startsWith(right) || right.startsWith(left);
}

function takePendingForBubble(text) {
  const matches = pending
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => promptMatchesBubble(item, text));
  if (!matches.length) return null;

  matches.sort((left, right) => {
    const exactDifference =
      Number(right.item.normalizedRaw === text) -
      Number(left.item.normalizedRaw === text);
    if (exactDifference) return exactDifference;
    return right.item.normalizedRaw.length - left.item.normalizedRaw.length;
  });
  const [{ item, index }] = matches;
  pending.splice(index, 1);
  return item;
}

function hasFeedbackForDomKey(anchor, domKey) {
  const parent = anchor.parentElement;
  if (!parent) return false;
  return Array.from(parent.querySelectorAll(".redpen-feedback")).some(
    (element) => element.dataset.domKey === domKey,
  );
}

function attachFeedbackBlock(bubble, anchor, block) {
  const bubbleWidth = Math.round(bubble.getBoundingClientRect().width);
  if (bubbleWidth > 0) {
    block.style.setProperty("--redpen-anchor-width", `${bubbleWidth}px`);
  }
  block.dataset.redpenTone = textColorIsLight(
    window.getComputedStyle(bubble).color,
  )
    ? "dark"
    : "light";
  anchor.insertAdjacentElement("afterend", block);
}

async function runRedpen(item, block) {
  const domKey = block.dataset.domKey;
  const redpenRequestId =
    item.redpenRequestId ||
    bridge?.createRequestId?.() ||
    `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  item.redpenRequestId = redpenRequestId;
  const request = { item, redpenRequestId };
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
    const response = await bridge.request(
      "/coach",
      {
        prompt: item.coachPrompt,
        requestId: item.id,
      },
      redpenRequestId,
    );
    clearTimeout(loadingTimer);
    if (!response || response.status === "skipped") {
      if (domKey && inFlightByDomKey.get(domKey) === request) {
        inFlightByDomKey.delete(domKey);
      }
      if (domKey) retryableByDomKey.delete(domKey);
      const feedbackPersisted = persistFeedbackState();
      if (feedbackPersisted) {
        bridge.ack?.(redpenRequestId);
        delete item.redpenRequestId;
      }
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
    const feedbackPersisted = rememberFeedback(domKey, response);
    if (feedbackPersisted) {
      bridge.ack?.(redpenRequestId);
      delete item.redpenRequestId;
    }
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
    const keepAttempt = error?.redpenPending === true;
    const previousRequestId = item.redpenRequestId;
    if (!keepAttempt) delete item.redpenRequestId;
    if (domKey) retryableByDomKey.set(domKey, item);
    const feedbackPersisted = persistFeedbackState();
    if (!keepAttempt && feedbackPersisted) {
      bridge?.ack?.(redpenRequestId);
    } else if (!keepAttempt) {
      item.redpenRequestId = previousRequestId;
    }
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
