import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../assets/chatgpt-app/renderer-inject.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({
  clearTimeout() {},
  console,
  document: { body: null },
  localStorage: {
    getItem() {
      return null;
    },
    setItem() {},
  },
  location: {
    hash: "",
    pathname: "/",
    search: "",
  },
  setInterval() {
    return 0;
  },
  setTimeout() {
    return 0;
  },
  window: {},
});

vm.runInContext(
  `(function () {
    ${source}
    globalThis.rendererTestApi = {
      canonicalUserBubbleElement,
      checkedLegacyDomKeys,
      collapseUserBubbleCandidate,
      dismissedDomKeys,
      feedbackAnchorForBubble,
      feedbackByDomKey,
      findLegacyDomKey,
      hashText,
      inFlightByDomKey,
      isLikelyUserMessageChild,
      mergeSubmissionCapture,
      migrateLegacyTimestampState,
      orderEntriesForPending,
      pending,
      promptMatchesBubble,
      promptTextsAreVariants,
      restoreFeedback,
      seenDomKeys,
      takePendingForBubble,
      userMessageCandidatesForGroup,
    };
  })();`,
  context,
);

const api = context.rendererTestApi;

test.beforeEach(() => {
  api.pending.length = 0;
  api.feedbackByDomKey.clear();
  api.checkedLegacyDomKeys.clear();
  api.dismissedDomKeys.clear();
  api.inFlightByDomKey.clear();
  api.seenDomKeys.clear();
  context.document.querySelectorAll = () => [];
});

function capture(normalizedRaw, at) {
  return {
    at,
    coachPrompt: normalizedRaw,
    id: `${at}-${normalizedRaw}`,
    normalizedRaw,
    rawPrompt: normalizedRaw,
  };
}

test("coalesces full and transient prefix captures from one submit", () => {
  const short = capture("你可以加log，我来帮你验证", 1000);
  const full = capture("你可以加log，我来帮你验证你的猜想", 1000);

  assert.equal(
    api.promptTextsAreVariants(short.normalizedRaw, full.normalizedRaw),
    true,
  );
  assert.equal(
    api.mergeSubmissionCapture(short, full).normalizedRaw,
    full.normalizedRaw,
  );
  assert.equal(
    api.mergeSubmissionCapture(full, short).normalizedRaw,
    full.normalizedRaw,
  );
});

test("does not coalesce unrelated captures or separate submissions", () => {
  const first = capture("first prompt", 1000);
  const unrelated = capture("second prompt", 1000);
  const laterPrefix = capture("first", 1300);

  assert.equal(api.mergeSubmissionCapture(first, unrelated), null);
  assert.equal(api.mergeSubmissionCapture(first, laterPrefix), null);
});

test("consumes one best capture when a bubble matches submit variants", () => {
  const short = capture("你可以加log，我来帮你验证", 1000);
  const full = capture("你可以加log，我来帮你验证你的猜想", 1000);
  api.pending.push(short, full);

  const selected = api.takePendingForBubble(
    "你可以加log，我来帮你验证你的猜想1:30 PM",
  );

  assert.equal(selected.normalizedRaw, full.normalizedRaw);
  assert.deepEqual(Array.from(api.pending), [short]);
});

test("does not match a partially rendered bubble", () => {
  const full = capture("你可以加log，我来帮你验证你的猜想", 1000);

  assert.equal(api.promptMatchesBubble(full, "你可以加log，我来帮你验证"), false);
});

test("keeps separate prefix-related submissions outside one event burst", () => {
  const first = capture("please verify this longer prompt", 1000);
  const second = capture("please verify this", 1300);
  api.pending.push(first, second);

  assert.equal(
    api.takePendingForBubble("please verify this longer prompt"),
    first,
  );
  assert.deepEqual(Array.from(api.pending), [second]);
  assert.equal(api.takePendingForBubble("please verify this"), second);
  assert.equal(api.pending.length, 0);
});

test("matches a new exact bubble before an older prefix match", () => {
  const item = capture("log", 1000);
  const older = { text: "log details" };
  const current = { text: "log" };
  api.pending.push(item);

  const ordered = Array.from(
    api.orderEntriesForPending([older, current]),
  );

  assert.equal(ordered[0], current);
  assert.equal(api.takePendingForBubble(ordered[0].text), item);
  assert.equal(api.pending.length, 0);
});

test("does not collapse an unrelated nested user control into a message", () => {
  const child = {
    contains(candidate) {
      return candidate === child;
    },
  };
  const parent = {
    contains(candidate) {
      return candidate === parent || candidate === child;
    },
  };
  const unique = [];

  api.collapseUserBubbleCandidate(unique, parent, "prompt");
  api.collapseUserBubbleCandidate(unique, child, "user menu");

  assert.equal(unique.length, 2);
  assert.equal(unique[0].bubble, parent);
  assert.equal(unique[1].bubble, child);
});

test("maps a nested user control back to its stable message bubble", () => {
  const bubble = {};
  const control = {
    closest(selector) {
      return selector === '[data-user-message-bubble="true"]'
        ? bubble
        : null;
    },
  };

  assert.equal(api.canonicalUserBubbleElement(control), bubble);
});

test("maps a timestamp wrapper down to its stable message bubble", () => {
  const bubble = {};
  const wrapper = {
    closest() {
      return null;
    },
    querySelector(selector) {
      return selector === '[data-user-message-bubble="true"]'
        ? bubble
        : null;
    },
  };

  assert.equal(api.canonicalUserBubbleElement(wrapper), bubble);
});

test("recognizes the stable user-message marker", () => {
  const element = {
    className: "",
    matches(selector) {
      return selector === '[data-user-message-bubble="true"]';
    },
  };

  assert.equal(api.isLikelyUserMessageChild(element), true);
});

test("uses the real message child instead of its timestamp wrapper", () => {
  const message = {
    className: "",
    matches(selector) {
      return selector === '[data-user-message-bubble="true"]';
    },
  };
  const timestamp = {
    className: "flex flex-row-reverse items-center gap-1",
    matches() {
      return false;
    },
  };
  const row = { className: "flex w-full items-center justify-end gap-1" };
  const group = {
    children: [row, timestamp],
    querySelector(selector) {
      return selector === '[data-user-message-bubble="true"]'
        ? message
        : null;
    },
  };

  assert.deepEqual(Array.from(api.userMessageCandidatesForGroup(group)), [
    message,
  ]);
});

test("keeps layout anchoring outside a horizontal message row", () => {
  const group = {};
  const row = {};
  const wrappedBubble = {
    closest() {
      return group;
    },
    parentElement: row,
  };
  const directBubble = {
    closest() {
      return group;
    },
    parentElement: group,
  };

  assert.equal(api.feedbackAnchorForBubble(wrappedBubble), group);
  assert.equal(api.feedbackAnchorForBubble(directBubble), directBubble);
});

test("migrates a legacy prompt-plus-timestamp feedback key", () => {
  const conversationKey = "local:test-thread";
  const text = "你可以加log，我来帮你验证你的猜想";
  const legacyDomKey = `${conversationKey}|${api.hashText(`${text}1:30 PM`)}|1`;
  const domKey = `${conversationKey}|${api.hashText(text)}|1`;
  const response = { rewrite: "full response", status: "ok" };
  const block = { dataset: { domKey: legacyDomKey } };
  api.feedbackByDomKey.set(legacyDomKey, response);
  api.seenDomKeys.add(legacyDomKey);
  context.document.querySelectorAll = () => [block];

  api.migrateLegacyTimestampState([
    {
      conversationKey,
      domKey,
      legacyTexts: [`${text}1:30 PM`],
      occurrence: 1,
      text,
    },
  ]);

  assert.equal(api.feedbackByDomKey.get(domKey), response);
  assert.equal(api.feedbackByDomKey.has(legacyDomKey), false);
  assert.equal(block.dataset.domKey, domKey);
  assert.equal(api.seenDomKeys.has(domKey), true);
  assert.equal(api.seenDomKeys.has(legacyDomKey), false);
});

test("does not guess that a legitimate time suffix is wrapper metadata", () => {
  const conversationKey = "local:test-thread";
  const storedText = "Let's meet at 1:30 PM";
  const currentText = "Let's meet at";
  const legacyDomKey =
    `${conversationKey}|${api.hashText(storedText)}|1`;
  const domKey = `${conversationKey}|${api.hashText(currentText)}|1`;
  const response = { rewrite: "stored response", status: "ok" };
  api.feedbackByDomKey.set(legacyDomKey, response);

  api.migrateLegacyTimestampState([
    {
      conversationKey,
      domKey,
      legacyTexts: [],
      occurrence: 1,
      text: currentText,
    },
  ]);

  assert.equal(api.feedbackByDomKey.has(domKey), false);
  assert.equal(api.feedbackByDomKey.get(legacyDomKey), response);
});

test("does not migrate a live request whose closure still owns the old key", () => {
  const conversationKey = "local:test-thread";
  const text = "prompt";
  const legacyText = "prompt1:30 PM";
  const legacyDomKey =
    `${conversationKey}|${api.hashText(legacyText)}|1`;
  const domKey = `${conversationKey}|${api.hashText(text)}|1`;
  const request = { item: capture(text, 1000), redpenRequestId: "live" };
  const leftover = capture(text, 1001);
  api.inFlightByDomKey.set(legacyDomKey, request);
  api.pending.push(leftover);

  api.migrateLegacyTimestampState([
    {
      conversationKey,
      domKey,
      legacyTexts: [legacyText],
      occurrence: 1,
      text,
    },
  ]);

  assert.equal(api.inFlightByDomKey.get(legacyDomKey), request);
  assert.equal(api.inFlightByDomKey.has(domKey), false);
  assert.equal(api.checkedLegacyDomKeys.has(domKey), false);
  assert.equal(api.seenDomKeys.has(domKey), true);
  assert.deepEqual(Array.from(api.pending), [leftover]);
});

test("does not reuse a dismissed historical message for a new submit", () => {
  const domKey = "local:test|dismissed|1";
  api.dismissedDomKeys.add(domKey);

  api.restoreFeedback([{ anchor: {}, bubble: {}, domKey }]);

  assert.equal(api.seenDomKeys.has(domKey), true);
});
