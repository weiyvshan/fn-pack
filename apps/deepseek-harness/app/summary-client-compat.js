#!/usr/bin/env node
"use strict";

const DEFAULT_OPTIONS = Object.freeze({ ttlMs: 60_000, limit: 256, retryMs: 1_000 });
const MAX_TIMER_MS = 0x7fffffff;
const MAX_LIMIT = 4096;
const SUMMARY_REGION = "//#region lib/types/client/changes-summary.js";
const REVIEW_REGION = "//#region lib/types/client/ReviewTab.js";
const REGION_END = "//#endregion";
const MARKER = "/* fnos-summary-client-compat */";
const REVIEW_SUMMARY_STATE = 'const summaryState = summary === void 0 || summary === "loading" ? "loading" : summary === "missing" ? "missing" : "ready";';
const REVIEW_MISSING_FRAGMENT = `summaryState === "missing" && (0, react_jsx_runtime.jsx)("p", {
						className: FileDiff_module_css_default.status,
						children: t("diff.missing")
					}),`;
const LEGACY_SUMMARY_CANONICAL = `//#region lib/types/client/changes-summary.js
var ChangesSummaryStore = class extends HostReadStore {
constructor() {
super({
loading: "loading",
failed: "missing",
retryable: () => false,
decode: async (response) => {
if (!response.ok) return "missing";
const value = await response.json();
return isChangesSummary(value) ? value : "missing";
}
});
}
load(sessionId, seq) {
return this.loadUrl(changesSummaryUrl(sessionId, seq));
}
};
//#endregion`;

/** Remove only JSDoc and non-string whitespace before comparing a locked compiled region. */
function normalizeLegacySummary(source) {
  let result = "";
  let quote = "";
  for (let at = 0; at < source.length; at += 1) {
    const char = source[at];
    if (quote !== "") {
      result += char;
      if (char === "\\") result += source[++at] ?? "";
      else if (char === quote) quote = "";
      continue;
    }
    if (char === '"' || char === "'" || char === "`") {
      quote = char;
      result += char;
      continue;
    }
    if (source.startsWith("/**", at)) {
      const end = source.indexOf("*/", at + 3);
      if (end < 0) return "";
      at = end + 1;
      continue;
    }
    if (!/\s/.test(char)) result += char;
  }
  return result;
}

function normalizeOptions(options = {}) {
  if (options === null || typeof options !== "object" || Array.isArray(options)) {
    throw new TypeError("summary client compatibility options must be an object");
  }
  for (const name of Object.keys(options)) {
    if (!Object.hasOwn(DEFAULT_OPTIONS, name)) throw new Error(`unknown summary client compatibility option ${name}`);
  }
  const merged = { ...DEFAULT_OPTIONS, ...options };
  for (const name of ["ttlMs", "retryMs"]) {
    if (!Number.isSafeInteger(merged[name]) || merged[name] < 1 || merged[name] > MAX_TIMER_MS) {
      throw new Error(`summary client compatibility requires ${name} between 1 and ${MAX_TIMER_MS}`);
    }
  }
  if (!Number.isSafeInteger(merged.limit) || merged.limit < 1 || merged.limit > MAX_LIMIT) {
    throw new Error(`summary client compatibility requires limit between 1 and ${MAX_LIMIT}`);
  }
  return Object.freeze(merged);
}

function regionOf(body, start) {
  if (typeof body !== "string") throw new TypeError("summary client compatibility body must be a string");
  const first = body.indexOf(start);
  if (first < 0 || body.indexOf(start, first + start.length) >= 0) return null;
  const end = body.indexOf(REGION_END, first + start.length);
  if (end < 0) return null;
  return { start: first, end: end + REGION_END.length, text: body.slice(first, end + REGION_END.length) };
}

function knownLegacy(summary, review) {
  return normalizeLegacySummary(summary) === normalizeLegacySummary(LEGACY_SUMMARY_CANONICAL)
    && review.includes(REVIEW_SUMMARY_STATE)
    && review.includes(REVIEW_MISSING_FRAGMENT);
}

function knownAdapted(summary, review) {
  return summary.includes(MARKER)
    && summary.includes('failed: "error",')
    && summary.includes('response.status === 404')
    && summary.includes('this.negativeCache')
    && summary.includes('removeNegative(url)')
    && review.includes(MARKER)
    && review.includes('summary === "error" ? "error" : "ready"')
    && review.includes('summaryState === "error"')
    && review.includes('_deepseek_ai_dsh_client_ui_primitives.Button');
}

function inspectKnownChangesSummaryClient(body) {
  const summary = regionOf(body, SUMMARY_REGION);
  const review = regionOf(body, REVIEW_REGION);
  if (summary === null || review === null || summary.start >= review.start) return null;
  if (knownLegacy(summary.text, review.text)) return { state: "legacy", summary, review };
  if (knownAdapted(summary.text, review.text)) return { state: "adapted", summary, review };
  return null;
}

function assertKnownChangesSummaryClient(body) {
  const known = inspectKnownChangesSummaryClient(body);
  if (known === null) throw new Error("unsupported ui-deliverables summary client bundle");
  return known.state;
}

function summaryRegion({ ttlMs, limit, retryMs }) {
  return `${SUMMARY_REGION}
		${MARKER}
		var ChangesSummaryStore = class extends HostReadStore {
			constructor() {
				super({
					loading: "loading",
					failed: "error",
					retryable: (state) => state === "error",
					decode: async (response) => {
						if (response.status === 404) return (await response.text()).trim() === "Change summary unavailable." ? "missing" : "error";
						if (!response.ok) return "error";
						const value = await response.json();
						return isChangesSummary(value) ? value : "error";
					}
				});
				this.negativeCache = new Map();
				this.negativeExpiry = new Map();
				this.retryAt = new Map();
				this.epoch = 0;
			}
			load(sessionId, seq) {
				const url = changesSummaryUrl(sessionId, seq);
				const now = Date.now();
				this.pruneNegatives(now);
				this.pruneRetries(now);
				const current = this.state.getSnapshot()[url];
				if (current === "missing") {
					if (this.negativeCache.has(url)) return Promise.resolve();
					this.state.update((state) => { if (state[url] === "missing") delete state[url]; });
				}
				if (current === "error" && (this.retryAt.get(url) || 0) > now) return Promise.resolve();
				const epoch = this.epoch;
				return this.loadUrl(url).then(() => {
					if (epoch !== this.epoch) return;
					const next = this.state.getSnapshot()[url];
					if (next === "missing") this.rememberNegative(url, Date.now());
					else this.removeNegative(url);
					if (next === "error") this.rememberRetry(url, Date.now());
					else this.retryAt.delete(url);
				});
			}
			reset() {
				this.epoch += 1;
				const now = Date.now();
				this.pruneNegatives(now);
				this.pruneRetries(now);
				super.reset();
				if (this.negativeCache.size > 0) this.state.set(Object.fromEntries(this.negativeCache));
			}
			async dispose() {
				this.epoch += 1;
				this.negativeCache.clear();
				this.negativeExpiry.clear();
				this.retryAt.clear();
				await super.dispose();
			}
			rememberNegative(url, now) {
				this.removeNegative(url, true);
				while (this.negativeCache.size >= ${limit}) {
					const oldest = this.negativeCache.keys().next().value;
					if (oldest === void 0) break;
					this.removeNegative(oldest);
				}
				this.negativeCache.set(url, "missing");
				this.negativeExpiry.set(url, now + ${ttlMs});
			}
			removeNegative(url, preserveState = false) {
				this.negativeCache.delete(url);
				this.negativeExpiry.delete(url);
				if (!preserveState && this.state.getSnapshot()[url] === "missing") {
					this.state.update((state) => { if (state[url] === "missing") delete state[url]; });
				}
			}
			pruneNegatives(now) {
				for (const [url, expiry] of this.negativeExpiry) {
					if (expiry <= now) this.removeNegative(url);
				}
			}
			rememberRetry(url, now) {
				this.retryAt.delete(url);
				while (this.retryAt.size >= ${limit}) {
					const oldest = this.retryAt.keys().next().value;
					if (oldest === void 0) break;
					this.retryAt.delete(oldest);
				}
				this.retryAt.set(url, now + ${retryMs});
			}
			pruneRetries(now) {
				for (const [url, retryAt] of this.retryAt) {
					if (retryAt <= now) this.retryAt.delete(url);
				}
			}
		};
		${REGION_END}`;
}

function rewriteReviewRegion(region) {
  const replacement = `const summaryState = summary === void 0 || summary === "loading" ? "loading" : summary === "missing" ? "missing" : summary === "error" ? "error" : "ready";\n\t\t\t${MARKER}`;
  const error = `${REVIEW_MISSING_FRAGMENT}\n\t\t\t\t\tsummaryState === "error" && (0, react_jsx_runtime.jsxs)("div", {\n\t\t\t\t\t\tclassName: FileDiff_module_css_default.status,\n\t\t\t\t\t\tchildren: [(0, react_jsx_runtime.jsx)("span", {\n\t\t\t\t\t\t\tchildren: t("diff.error")\n\t\t\t\t\t\t}), (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.Button, {\n\t\t\t\t\t\t\tsize: "sm",\n\t\t\t\t\t\t\tonClick: () => {\n\t\t\t\t\t\t\t\tloadChangesSummary(sessionId, seq);\n\t\t\t\t\t\t\t},\n\t\t\t\t\t\t\tchildren: t("presented.retry")\n\t\t\t\t\t\t})]\n\t\t\t\t\t}),`;
  return region.replace(REVIEW_SUMMARY_STATE, replacement).replace(REVIEW_MISSING_FRAGMENT, error);
}

function rewriteChangesSummaryClient(body, options) {
  const known = inspectKnownChangesSummaryClient(body);
  if (known === null || known.state === "adapted") return body;
  const normalized = normalizeOptions(options);
  const rewrittenSummary = summaryRegion(normalized);
  const rewrittenReview = rewriteReviewRegion(known.review.text);
  return `${body.slice(0, known.summary.start)}${rewrittenSummary}${body.slice(known.summary.end, known.review.start)}${rewrittenReview}${body.slice(known.review.end)}`;
}

module.exports = {
  DEFAULT_OPTIONS,
  MAX_LIMIT,
  MAX_TIMER_MS,
  assertKnownChangesSummaryClient,
  normalizeOptions,
  rewriteChangesSummaryClient,
};
