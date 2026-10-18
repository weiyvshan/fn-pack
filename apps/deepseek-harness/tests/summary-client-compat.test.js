#!/usr/bin/env node
"use strict";

const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const {
  DEFAULT_OPTIONS,
  MAX_LIMIT,
  MAX_TIMER_MS,
  assertKnownChangesSummaryClient,
  normalizeOptions,
  rewriteChangesSummaryClient,
} = require("../app/summary-client-compat.js");

const fixture = fs.readFileSync(path.join(__dirname, "fixtures", "summary-client-bundle.js"), "utf8");
const rewritten = rewriteChangesSummaryClient(fixture);

function regionOf(body, name) {
  const start = body.indexOf(name);
  const end = body.indexOf("//#endregion", start);
  assert.notEqual(start, -1, `missing ${name}`);
  assert.notEqual(end, -1, `unterminated ${name}`);
  return body.slice(start, end + "//#endregion".length);
}

function outsideLockedRegions(body) {
  const summary = regionOf(body, "//#region lib/types/client/changes-summary.js");
  const review = regionOf(body, "//#region lib/types/client/ReviewTab.js");
  return body.replace(summary, "<summary>").replace(review, "<review>");
}

assert.deepEqual(DEFAULT_OPTIONS, { ttlMs: 60_000, limit: 256, retryMs: 1_000 });
assert.deepEqual(normalizeOptions(), DEFAULT_OPTIONS);
assert.deepEqual(normalizeOptions({ ttlMs: 2, limit: 3, retryMs: 4 }), { ttlMs: 2, limit: 3, retryMs: 4 });
for (const options of [null, [], { ttlMs: 0 }, { limit: 1.5 }, { retryMs: "1" }, { extra: 1 }, { constructor: 1 }, { toString: 1 }, JSON.parse('{"__proto__": 1}'), { ttlMs: MAX_TIMER_MS + 1 }, { limit: MAX_LIMIT + 1 }]) {
  assert.throws(() => normalizeOptions(options));
}
assert.equal(assertKnownChangesSummaryClient(fixture), "legacy");
assert.equal(assertKnownChangesSummaryClient(rewritten), "adapted");
assert.equal(rewriteChangesSummaryClient(rewritten), rewritten);
assert.equal(outsideLockedRegions(rewritten), outsideLockedRegions(fixture));
assert.match(regionOf(rewritten, "//#region lib/types/client/changes-summary.js"), /failed: "error"/);
assert.match(regionOf(rewritten, "//#region lib/types/client/ReviewTab.js"), /summaryState === "error"/);
const legacySummary = regionOf(fixture, "//#region lib/types/client/changes-summary.js");
const withAddedMethod = fixture.replace(legacySummary, legacySummary.replace("\n\t\t};\n\t\t//#endregion", "\n\t\t\textra() { return 1; }\n\t\t};\n\t\t//#endregion"));
const withAddedField = fixture.replace(legacySummary, legacySummary.replace("var ChangesSummaryStore = class extends HostReadStore {", "var ChangesSummaryStore = class extends HostReadStore {\n\t\t\textra = 1;"));
const withChangedLoad = fixture.replace(legacySummary, legacySummary.replace("return this.loadUrl(changesSummaryUrl(sessionId, seq));", "this.observe();\n\t\t\t\treturn this.loadUrl(changesSummaryUrl(sessionId, seq));"));
const withLineComment = fixture.replace(legacySummary, legacySummary.replace("return this.loadUrl(changesSummaryUrl(sessionId, seq));", "// non-JSDoc syntax remains part of the locked source\n\t\t\t\treturn this.loadUrl(changesSummaryUrl(sessionId, seq));"));
for (const variant of [
  "unknown bundle",
  fixture.replace('children: t("diff.missing")', 'children: t("unexpected")'),
  `${fixture}\n${regionOf(fixture, "//#region lib/types/client/changes-summary.js")}`,
  `${regionOf(fixture, "//#region lib/types/client/ReviewTab.js")}\n${regionOf(fixture, "//#region lib/types/client/changes-summary.js")}`,
  withAddedMethod,
  withAddedField,
  withChangedLoad,
  withLineComment,
]) {
  assert.equal(rewriteChangesSummaryClient(variant), variant, "unknown variants remain byte-for-byte unchanged");
  assert.equal(rewriteChangesSummaryClient(variant, { extra: 1 }), variant, "unknown variants do not evaluate rewrite options");
  assert.throws(() => assertKnownChangesSummaryClient(variant));
}

class SnapshotStore {
  constructor(value) { this.value = value; }
  getSnapshot() { return this.value; }
  set(value) { this.value = value; }
  update(mutator) { mutator(this.value); }
}

function runFixture(source) {
  let now = 0;
  let calls = 0;
  let fetchImpl = async () => { throw new Error("no response configured"); };
  const context = {
    AbortController,
    AbortSignal,
    Date: { now: () => now },
    Map,
    Object,
    Promise,
    Response,
    Set,
    URLSearchParams,
    _deepseek_ai_dsh_client_store: { createSnapshotStore: value => new SnapshotStore(value) },
    fetch: (url, init) => {
      calls += 1;
      return fetchImpl(url, init);
    },
    react: {
      useMemo: factory => factory(),
      useEffect: effect => { effect(); },
      useState: value => [value, () => {}],
    },
    react_jsx_runtime: {
      jsx: (type, props) => ({ type, props }),
      jsxs: (type, props) => ({ type, props }),
      Fragment: "fragment",
    },
    _deepseek_ai_dsh_client_ui_primitives: new Proxy({}, { get: (_, key) => String(key) }),
    FileDiff: "FileDiff",
    FileDiff_module_css_default: new Proxy({}, { get: (_, key) => String(key) }),
    ReviewTab_module_css_default: new Proxy({}, { get: (_, key) => String(key) }),
    parseChangesReviewAddress: () => ({ sessionId: "s", seq: 1, turn: 2 }),
    fileAddressFor: () => "file",
  };
  vm.runInNewContext(source, context);
  return {
    Store: context.ChangesSummaryStore,
    ReviewTab: context.ReviewTab,
    calls: () => calls,
    now: value => { now = value; },
    reply: fn => { fetchImpl = fn; },
  };
}

function validSummary() {
  return { turn: 1, files: [], total: 0, added: 0, deleted: 0 };
}

(async () => {
  const harness = runFixture(rewritten);
  const store = new harness.Store();
  harness.reply(() => Promise.resolve(new Response("Change summary unavailable.", { status: 404 })));
  await store.load("s", 1);
  assert.equal(store.state.getSnapshot()["api/changes.summary?sessionId=s&seq=1"], "missing");
  store.reset();
  assert.equal(store.state.getSnapshot()["api/changes.summary?sessionId=s&seq=1"], "missing");
  await store.load("s", 1);
  assert.equal(harness.calls(), 1, "confirmed missing state survives immediate reconnect");
  harness.now(60_000);
  harness.reply(() => Promise.resolve(Response.json(validSummary())));
  await store.load("s", 1);
  assert.deepEqual(store.state.getSnapshot()["api/changes.summary?sessionId=s&seq=1"], validSummary());
  assert.equal(harness.calls(), 2, "expired negative cache releases the same sequence");

  const errors = [
    () => Promise.resolve(new Response("<html>not found</html>", { status: 404 })),
    () => Promise.resolve(new Response("failure", { status: 500 })),
    () => Promise.resolve(new Response("rate limited", { status: 429 })),
    () => Promise.resolve(new Response("auth", { status: 401 })),
    () => Promise.resolve(new Response("forbidden", { status: 403 })),
    () => Promise.resolve(new Response("{", { status: 200, headers: { "content-type": "application/json" } })),
    () => Promise.resolve(Response.json({ turn: "invalid", files: [], total: 0, added: 0, deleted: 0 })),
    () => Promise.reject(new Error("offline")),
  ];
  for (let seq = 10; seq < 10 + errors.length; seq += 1) {
    harness.reply(errors[seq - 10]);
    await store.load("s", seq);
    assert.equal(store.state.getSnapshot()[`api/changes.summary?sessionId=s&seq=${seq}`], "error");
  }
  const beforeBackoff = harness.calls();
  harness.reply(() => Promise.resolve(Response.json(validSummary())));
  await store.load("s", 17);
  assert.equal(harness.calls(), beforeBackoff, "one-second retry backoff blocks dense manual or render retries");
  harness.now(61_000);
  await store.load("s", 17);
  assert.deepEqual(store.state.getSnapshot()["api/changes.summary?sessionId=s&seq=17"], validSummary());
  harness.reply(() => Promise.resolve(new Response("failure", { status: 500 })));
  for (let seq = 40; seq < 297; seq += 1) await store.load("retry", seq);
  assert.equal(store.retryAt.size, 256, "retry backoff metadata has the same strict capacity bound");
  harness.now(62_000);
  harness.reply(() => Promise.resolve(Response.json(validSummary())));
  await store.load("retry", 999);
  assert.equal(store.retryAt.size, 0, "expired retry backoff metadata is pruned on the next demand");

  harness.reply(() => Promise.resolve(new Response("Change summary unavailable.", { status: 404 })));
  for (let seq = 100; seq < 357; seq += 1) await store.load("cap", seq);
  const negativeStates = Object.entries(store.state.getSnapshot()).filter(([, value]) => value === "missing");
  assert.equal(store.negativeCache.size, 256);
  assert.equal(negativeStates.length, 256, "standing missing state is bounded with its cache");
  store.reset();
  assert.equal(Object.keys(store.state.getSnapshot()).length, 256);

  let resolveLate;
  let lateSignal;
  harness.reply((_url, init) => new Promise(resolve => {
    lateSignal = init.signal;
    resolveLate = resolve;
  }));
  const late = store.load("late", 1);
  store.reset();
  assert.equal(lateSignal.aborted, true, "reset aborts the real HostReadStore generation signal");
  resolveLate(new Response("Change summary unavailable.", { status: 404 }));
  await late;
  assert.equal(store.state.getSnapshot()["api/changes.summary?sessionId=late&seq=1"], undefined, "old generation cannot publish a late state");
  assert.equal(store.negativeCache.has("api/changes.summary?sessionId=late&seq=1"), false, "old generation cannot poison the negative cache");

  let resolveDispose;
  let disposeSignal;
  harness.reply((_url, init) => new Promise(resolve => {
    disposeSignal = init.signal;
    resolveDispose = resolve;
  }));
  const pending = store.load("disposed", 1);
  let disposed = false;
  const disposing = store.dispose().then(() => { disposed = true; });
  assert.equal(disposeSignal.aborted, true, "dispose aborts the real HostReadStore lifetime signal");
  await Promise.resolve();
  assert.equal(disposed, false, "dispose waits for the base store's pending read");
  resolveDispose(new Response("Change summary unavailable.", { status: 404 }));
  await Promise.all([pending, disposing]);
  assert.equal(store.negativeCache.has("api/changes.summary?sessionId=disposed&seq=1"), false, "dispose rejects late negative-cache publication");

  let summaryPhase = "missing";
  let renderedRetries = 0;
  const reviewProps = {
    useTabInfo: () => ({ tab: {
      id: "tab", contentId: "dsh-resource://changes-review/session/s/1/2", navigation: { revision: 1 },
      signal: { addEventListener() {}, removeEventListener() {} }, actions: { openResource() {} },
    } }),
    sessionId: "s",
    useSessions: select => select({ byId: { s: { cwd: "/tmp" } } }),
    useStore: () => undefined,
    actions: { navigated() {}, forget() {}, selected() {}, toggledSplit() {}, toggledWrap() {} },
    useChangesSummary: select => select({ "api/changes.summary?sessionId=s&seq=1": summaryPhase }),
    useChangesDiff: select => select({}),
    usePresentedOpen: select => select({}),
    usePresentedHost: select => select({ available: true }),
    loadChangesSummary() { renderedRetries += 1; summaryPhase = "loading"; },
    loadChangesDiff() {},
    reloadPresentedHost() {},
    openChanged() {},
    t: key => key,
    renderSlot: () => null,
  };
  const renderReview = () => harness.ReviewTab(reviewProps);
  const statusOf = rendered => rendered.props.children.find(child => child?.props?.className === "status");
  const missing = renderReview();
  assert.equal(missing.props["data-review-state"], "missing");
  assert.equal(statusOf(missing).props.children, "diff.missing");
  summaryPhase = "loading";
  const loading = renderReview();
  assert.equal(loading.props["data-review-state"], "loading");
  assert.equal(statusOf(loading).props.children, "diff.loading");
  summaryPhase = "error";
  const errored = renderReview();
  assert.equal(errored.props["data-review-state"], "error");
  const errorNode = statusOf(errored);
  assert.equal(errorNode.type, "div");
  assert.equal(errorNode.props.children[0].type, "span");
  assert.equal(errorNode.props.children[0].props.children, "diff.error");
  const retry = errorNode.props.children[1];
  assert.equal(retry.type, "Button");
  assert.equal(retry.props.size, "sm");
  assert.equal(retry.props.children, "presented.retry");
  retry.props.onClick();
  assert.equal(renderedRetries, 1);
  const afterRetry = renderReview();
  assert.equal(afterRetry.props["data-review-state"], "loading");
  summaryPhase = validSummary();
  const ready = renderReview();
  assert.equal(ready.props["data-review-state"], "ready");
  assert.equal(statusOf(ready), undefined);

  process.stdout.write("summary-client-compat tests passed\n");
})().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
