#!/usr/bin/env node
"use strict";

const assert = require("assert/strict");
const { once } = require("events");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const vm = require("vm");
const {
  BETTER_SIDEBAR_CLIENT_ROUTES,
  BETTER_SIDEBAR_CONTAINER_MARKERS,
  BETTER_SIDEBAR_WS_MARKER,
  BUILTIN_REWRITE_PREFIXES,
  EXPORT_DIR_NAME,
  EXPORT_OPEN_PATH,
  FNOS_OPEN_ENHANCER_PATH,
  MARKER,
  MOBILE_UI_CLIENT_ROUTE,
  MOBILE_UI_MARKERS,
  PLUGIN_MANAGER_MARKER,
  REMOTE_WEB_UI_CONTAINER_MARKERS,
  REMOTE_WEB_UI_MARKERS,
  SETTINGS_CLIENT_MARKER,
  SESSION_EXPORT_PATH,
  TRIM_WEB_APP_PATH,
  backendAuthCookieName,
  buildHeaders,
  fnosBrowserConfig,
  handleExportOpenRequest,
  handleSessionExportRequest,
  isAdaptedPluginClientPath,
  isAdminRequest,
  isGatewayPath,
  isHtmlContentType,
  isPathWithinRoot,
  normalizePrefix,
  parsePid,
  parseTarget,
  performExportOpen,
  performSessionExport,
  pickExportDestination,
  handlePathStatRequest,
  statProbeIsDirectory,
  readFnosEnvConfig,
  readLaunchToken,
  readDynamicPrefixes,
  resolveExportSource,
  rewriteBody,
  rewriteBetterSidebarWebSocketResilience,
  rewriteMobileUiRegistration,
  rewritePluginManagerLoopback,
  rewriteRemoteWebUiLoopback,
  rewriteSettingsHostPersistence,
  rewriteLocation,
  rewriteSetCookie,
  runtimeAdapterScript,
  sanitizeExportBasename,
  validateSessionExportPayload,
  requestBackendAuthCookie,
  mergeBackendAuthCookie,
  startGatewayProxy,
  stripPrefix,
} = require("../app/gateway-proxy.js");
const {
  emptyRegistry,
  setPlugin,
  writeRegistry,
} = require("../app/gateway-compat.js");

const prefix = "/app/deepseek-harness";
const target = { host: "127.0.0.1", port: 31880 };

assert.equal(isAdminRequest({}), false);
assert.equal(isAdminRequest({ "x-trim-isadmin": "false" }), false);
assert.equal(isAdminRequest({ "x-trim-isadmin": "true" }), true);
assert.equal(isAdminRequest({ "x-trim-isadmin": "TRUE" }), true);
assert.equal(isGatewayPath(prefix, prefix), true);
assert.equal(isGatewayPath(`${prefix}/api?q=1`, prefix), true);
assert.equal(isGatewayPath("/unrelated", prefix), false);
assert.ok(BUILTIN_REWRITE_PREFIXES.includes("/open-in-app/"));

assert.equal(normalizePrefix(`${prefix}/`), prefix);
assert.throws(() => normalizePrefix("/unsafe/../path"));
assert.deepEqual(parseTarget("127.0.0.1:31880"), target);
assert.throws(() => parseTarget("127.0.0.1:70000"));
assert.equal(parsePid("1234"), 1234);
assert.throws(() => parsePid("0"));

const tokenFileRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gateway-token-file-test-"));
try {
  const tokenFile = path.join(tokenFileRoot, "launch.token");
  fs.writeFileSync(tokenFile, "invalid token\n", { mode: 0o600 });
  assert.throws(() => readLaunchToken(tokenFile), /invalid token/);
  fs.writeFileSync(tokenFile, `${"b".repeat(43)}\n`, { mode: 0o600 });
  if (process.platform !== "win32") {
    fs.chmodSync(tokenFile, 0o644);
    assert.throws(() => readLaunchToken(tokenFile), /permissions/);
    fs.chmodSync(tokenFile, 0o600);
  }
  assert.equal(readLaunchToken(tokenFile), "b".repeat(43));
} finally {
  fs.rmSync(tokenFileRoot, { recursive: true, force: true });
}

assert.equal(stripPrefix(prefix, prefix), "/");
assert.equal(stripPrefix(`${prefix}/api/test?q=1`, prefix), "/api/test?q=1");
assert.equal(
  stripPrefix(`${prefix}/sidebar/api/fs.list?q=1`, prefix),
  "/sidebar/api/fs.list?q=1"
);
assert.equal(stripPrefix("/unrelated", prefix), "/unrelated");

const headers = buildHeaders(
  {
    host: "nas.example",
    origin: "https://nas.example",
    "accept-encoding": "gzip",
    "x-trim-userid": "1000",
    "x-trim-isadmin": "true",
    "x-trim-username": "admin",
    "sec-fetch-site": "cross-site",
  },
  target,
  { gatewayAuthenticated: true }
);
assert.equal(headers.host, "127.0.0.1:31880");
assert.equal(headers.connection, "close");
assert.equal(headers.origin, undefined);
assert.equal(headers["sec-fetch-site"], "same-origin");
assert.equal(headers["accept-encoding"], undefined);
assert.equal(headers["x-trim-isadmin"], undefined);
assert.equal(
  isAdaptedPluginClientPath("/plugins/@linxin666/dsh-client-ui-plugin-manager/client.js?rev=abc"),
  true,
);
assert.equal(
  isAdaptedPluginClientPath("/plugins/@linxin666/dsh-remote-web-ui/client.js?rev=abc"),
  true,
);
assert.equal(
  isAdaptedPluginClientPath("/plugins/@linxin666/dsh-web-all/client.js?rev=abc"),
  true,
);
assert.equal(
  isAdaptedPluginClientPath("/plugins/@deepseek-ai/dsh-client-ui-settings/client.js?rev=abc"),
  true,
);
assert.equal(
  isAdaptedPluginClientPath(
    "/plugins/??@deepseek-ai/dsh-client-ui-layout/client.js,@deepseek-ai/dsh-client-ui-settings/client.js&rev=abc",
  ),
  true,
);
assert.equal(
  isAdaptedPluginClientPath(
    "/plugins/??@deepseek-ai/dsh-client-ui-layout/client.js,@linxin666/dsh-web-all/client.js&rev=abc",
  ),
  true,
);
assert.equal(
  isAdaptedPluginClientPath(
    "/plugins/??@deepseek-ai/dsh-client-ui-layout/client.js,@linxin666/dsh-remote-web-ui/client.js&rev=abc",
  ),
  true,
);
assert.equal(isAdaptedPluginClientPath(`/plugins/${MOBILE_UI_CLIENT_ROUTE}?rev=abc`), true);
assert.equal(
  isAdaptedPluginClientPath(
    `/plugins/??@deepseek-ai/dsh-client-ui-layout/client.js,${MOBILE_UI_CLIENT_ROUTE}&rev=abc`,
  ),
  true,
);
assert.equal(isAdaptedPluginClientPath("/plugins/example/other/client.js?rev=abc"), false);
assert.equal(isAdaptedPluginClientPath("/api/pair/heartbeat"), false);

const freshHeaders = buildHeaders(
  {
    "if-none-match": '"cached-plugin"',
    "if-modified-since": "Sat, 22 Aug 2026 00:00:00 GMT",
  },
  target,
  { disableRevalidation: true },
);
assert.equal(freshHeaders["if-none-match"], undefined);
assert.equal(freshHeaders["if-modified-since"], undefined);

const untrustedHeaders = buildHeaders(
  { host: "nas.example", "sec-fetch-site": "same-origin" },
  target,
  { upgrade: true }
);
assert.equal(untrustedHeaders.host, "127.0.0.1:31880");
assert.equal(untrustedHeaders["sec-fetch-site"], undefined);
assert.equal(untrustedHeaders.connection, undefined);

const html = '<!doctype html><html><head></head><body><script src="/assets/app.js"></script></body></html>';
assert.equal(isHtmlContentType("text/html; charset=utf-8"), true);
assert.equal(isHtmlContentType("application/xhtml+xml"), true);
assert.equal(isHtmlContentType("text/javascript"), false);
const rewrittenHtml = rewriteBody(html, prefix, [], "text/html; charset=utf-8");
assert.match(rewrittenHtml, new RegExp(MARKER));
assert.match(rewrittenHtml, /<base href="\/app\/deepseek-harness\/">/);
assert.match(rewrittenHtml, /src="\/app\/deepseek-harness\/assets\/app\.js"/);
assert.match(rewrittenHtml, /window\.fetch = function/);
assert.match(rewrittenHtml, /window\.__DSH_FNOS__=/);
assert.match(rewrittenHtml, /<script src="\/app\/deepseek-harness\/__fnos\/trim-web-app\.js"><\/script>/);
assert.match(rewrittenHtml, /<script src="\/app\/deepseek-harness\/__fnos\/fnos-open\.js"><\/script>/);
assert.ok(
  rewrittenHtml.indexOf(`${prefix}${TRIM_WEB_APP_PATH}`)
    < rewrittenHtml.indexOf(`${prefix}${FNOS_OPEN_ENHANCER_PATH}`),
);
assert.ok(
  rewrittenHtml.indexOf(`${prefix}${FNOS_OPEN_ENHANCER_PATH}`)
    < rewrittenHtml.indexOf(`${MARKER}: browser routes`),
);
assert.equal(rewriteBody(rewrittenHtml, prefix, [], "text/html"), rewrittenHtml);

const fnosEnvConfig = {
  visibleRoots: ["/vol1/1000", "/vol1/@apphome/deepseek-harness"],
  workspaceRoot: "/vol1/1000/dsh-workspace",
  homeRoot: "/vol1/@apphome/deepseek-harness/.dsh",
};
const injectedHtml = rewriteBody(html, prefix, [], "text/html; charset=utf-8", fnosEnvConfig);
assert.match(injectedHtml, /"prefix":"\/app\/deepseek-harness"/);
assert.match(injectedHtml, /"sdkPath":"\/app\/deepseek-harness\/__fnos\/trim-web-app\.js"/);
assert.match(injectedHtml, /"exportPath":"\/app\/deepseek-harness\/__fnos\/export-open"/);
assert.match(injectedHtml, /"statPath":"\/app\/deepseek-harness\/__fnos\/stat"/);
assert.match(injectedHtml, /"sessionExportPath":"\/app\/deepseek-harness\/__fnos\/export-session"/);
assert.ok(injectedHtml.includes('"visibleRoots":["/vol1/1000","/vol1/@apphome/deepseek-harness"]'));
const browserConfig = JSON.parse(
  injectedHtml.match(/window\.__DSH_FNOS__=(\{.*?\});<\/script>/s)[1],
);
assert.deepEqual(
  browserConfig,
  fnosBrowserConfig(prefix, fnosEnvConfig),
);
const htmlInjectionConfig = rewriteBody(
  html,
  prefix,
  [],
  "text/html; charset=utf-8",
  { visibleRoots: [], workspaceRoot: "/vol1/<script>", homeRoot: null },
);
assert.doesNotMatch(htmlInjectionConfig, /__DSH_FNOS__=\{[^}]*"</);

const javascriptWithHtmlLiteral = [
  'const template = "<html><head></head><body></body></html>";',
  'const chunk = "/sidebar/bundle/editor.js";',
].join("\n");
const rewrittenJavascriptWithHtmlLiteral = rewriteBody(
  javascriptWithHtmlLiteral,
  prefix,
  ["/sidebar/"],
  "text/javascript; charset=utf-8",
);
assert.doesNotMatch(rewrittenJavascriptWithHtmlLiteral, new RegExp(MARKER));
assert.ok(rewrittenJavascriptWithHtmlLiteral.includes(`${prefix}/sidebar/bundle/editor.js`));
new vm.Script(rewrittenJavascriptWithHtmlLiteral);

const rpcProtocolBundle = [
  'if (channel !== "/api") throw new Error("unexpected channel");',
  'const request = new URL(`${channel}/${endpoint}`, location.origin);',
].join("\n");
assert.equal(rewriteBody(rpcProtocolBundle, prefix), rpcProtocolBundle);

const settings = [
  `const marker = "${SETTINGS_CLIENT_MARKER}";`,
  'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";',
].join("\n");
const rewrittenSettings = rewriteSettingsHostPersistence(settings);
assert.match(rewrittenSettings, /const persistence = "host";/);
assert.equal(rewriteSettingsHostPersistence(rewrittenSettings), rewrittenSettings);
assert.equal(rewriteBody(settings, prefix), rewrittenSettings);
assert.equal(
  rewriteSettingsHostPersistence('const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";'),
  'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";',
);
const duplicateSettingsAssignment = `${settings}\nconst legacy = connection.isLoopback ? "host" : "memory";`;
assert.equal(rewriteSettingsHostPersistence(duplicateSettingsAssignment), duplicateSettingsAssignment);

const pluginManagerBundle = [
  `throw new Error("${PLUGIN_MANAGER_MARKER}")`,
  'const face = { isLoopback: connection.isLoopback };',
  'const compactFace = { isLoopback:connection.isLoopback };',
].join("\n");
const rewrittenPluginManager = rewriteBody(pluginManagerBundle, prefix);
assert.match(rewrittenPluginManager, /isLoopback: true/);
assert.doesNotMatch(rewrittenPluginManager, /connection\.isLoopback/);
assert.equal(rewritePluginManagerLoopback(rewrittenPluginManager), rewrittenPluginManager);
assert.equal(
  rewritePluginManagerLoopback('const face = { isLoopback: connection.isLoopback };'),
  'const face = { isLoopback: connection.isLoopback };',
);
assert.equal(
  rewritePluginManagerLoopback(`const marker = "${PLUGIN_MANAGER_MARKER}"; const face = { isLoopback: e.isLoopback };`),
  `const marker = "${PLUGIN_MANAGER_MARKER}"; const face = { isLoopback: e.isLoopback };`,
);

const remoteWebUiBundle = [
  'window.__ModuleLoader__.load({',
  '\tid: "@linxin666/dsh-remote-web-ui",',
  '\tconst heartbeatPath = "/api/pair/heartbeat";',
  '\tconst loopback = ctx.get("connection")?.isLoopback ?? true;',
  '\tif (isLoopbackHostname(window.location.hostname)) return false;',
  '\tconst unrelated = connection?.isLoopback;',
  '\tctx.effect(runtime, "remote-web-ui: pair flow + heartbeats");',
  '\tctx.effect(channel, "remote-web-ui: remote desktop channel");',
  '});',
].join("\n");
const rewrittenRemoteWebUi = rewriteRemoteWebUiLoopback(remoteWebUiBundle);
assert.match(rewrittenRemoteWebUi, /const loopback = true;/);
assert.match(rewrittenRemoteWebUi, /if \(true\) return false;/);
assert.match(rewrittenRemoteWebUi, /const unrelated = connection\?\.isLoopback;/);
assert.equal(rewriteRemoteWebUiLoopback(rewrittenRemoteWebUi), rewrittenRemoteWebUi);
const parameterizedRemoteWebUiBundle = remoteWebUiBundle.replace(
  "if (isLoopbackHostname(window.location.hostname)) return false;",
  "if (isLoopbackHostname(hostname)) return false;",
);
const rewrittenParameterizedRemoteWebUi = rewriteRemoteWebUiLoopback(parameterizedRemoteWebUiBundle);
assert.match(rewrittenParameterizedRemoteWebUi, /const loopback = true;/);
assert.match(rewrittenParameterizedRemoteWebUi, /if \(true\) return false;/);
assert.doesNotMatch(rewrittenParameterizedRemoteWebUi, /isLoopbackHostname\(hostname\)/);
const aggregateRemoteWebUiBundle = remoteWebUiBundle.replace(
  REMOTE_WEB_UI_CONTAINER_MARKERS[0],
  REMOTE_WEB_UI_CONTAINER_MARKERS[1],
);
const rewrittenAggregateRemoteWebUi = rewriteRemoteWebUiLoopback(aggregateRemoteWebUiBundle);
assert.match(rewrittenAggregateRemoteWebUi, /const loopback = true;/);
assert.match(rewrittenAggregateRemoteWebUi, /if \(true\) return false;/);
const rewrittenCombinedRemoteWebUi = rewriteRemoteWebUiLoopback(
  `${remoteWebUiBundle}\n${aggregateRemoteWebUiBundle}`,
);
assert.equal(rewrittenCombinedRemoteWebUi.match(/const loopback = true;/g)?.length, 2);
assert.equal(rewrittenCombinedRemoteWebUi.match(/if \(true\) return false;/g)?.length, 2);
for (const [index, marker] of REMOTE_WEB_UI_MARKERS.entries()) {
  const missingMarker = remoteWebUiBundle.replace(marker, `missing-remote-marker-${index}`);
  assert.equal(rewriteRemoteWebUiLoopback(missingMarker), missingMarker);
}
const unknownRemoteContainer = remoteWebUiBundle.replace(
  REMOTE_WEB_UI_CONTAINER_MARKERS[0],
  'id: "@example/unknown-remote-ui"',
);
assert.equal(rewriteRemoteWebUiLoopback(unknownRemoteContainer), unknownRemoteContainer);
const unknownRemoteWebUiShape = remoteWebUiBundle.replace(
  'const loopback = ctx.get("connection")?.isLoopback ?? true;',
  'const loopback=ctx.get("connection")?.isLoopback??true;',
);
assert.equal(rewriteRemoteWebUiLoopback(unknownRemoteWebUiShape), unknownRemoteWebUiShape);
const duplicateRemoteAssignment = `${remoteWebUiBundle}\nconst loopback = ctx.get("connection")?.isLoopback ?? true;`;
assert.equal(rewriteRemoteWebUiLoopback(duplicateRemoteAssignment), duplicateRemoteAssignment);
const ambiguousRemoteChannelFence = `${remoteWebUiBundle}\nif (isLoopbackHostname(hostname)) return false;`;
assert.equal(rewriteRemoteWebUiLoopback(ambiguousRemoteChannelFence), ambiguousRemoteChannelFence);
assert.equal(
  rewriteRemoteWebUiLoopback('const loopback = ctx.get("connection")?.isLoopback ?? true;'),
  'const loopback = ctx.get("connection")?.isLoopback ?? true;',
);

function betterSidebarSocketEffect(channel) {
  return [
    `\t\t\tfunction ${channel === "agent-terminals" ? "terminalEffect" : "openEffect"}() {`,
    "\t\t\t\tlet socket = null;",
    "\t\t\t\tlet retry;",
    "\t\t\t\tlet closed = false;",
    "\t\t\t\tlet failures = 0;",
    "\t\t\t\tconst connect = () => {",
    "\t\t\t\t\tif (closed) return;",
    `\t\t\t\t\tconst url = new URL("/sidebar/ws/${channel}", location.origin);`,
    "\t\t\t\t\turl.protocol = url.protocol === \"https:\" ? \"wss:\" : \"ws:\";",
    "\t\t\t\t\tsocket = new WebSocket(url.toString());",
    "\t\t\t\t\tsocket.onmessage = (event) => { void event; };",
    "\t\t\t\t\tsocket.onclose = () => {",
    "\t\t\t\t\t\tif (closed) return;",
    "\t\t\t\t\t\tfailures += 1;",
    "\t\t\t\t\t\tif (failures >= FAILURE_LIMIT) {",
    `\t\t\t\t\t\t\tconsole.error("[dsh-better-sidebar] ${channel} connection failed; stopping reconnect loop");`,
    "\t\t\t\t\t\t\treturn;",
    "\t\t\t\t\t\t}",
    "\t\t\t\t\t\tretry = window.setTimeout(connect, 2e3);",
    "\t\t\t\t\t};",
    "\t\t\t\t};",
    "\t\t\t\tconnect();",
    "\t\t\t\treturn () => {",
    "\t\t\t\t\tclosed = true;",
    "\t\t\t\t\twindow.clearTimeout(retry);",
    "\t\t\t\t\tsocket?.close();",
    "\t\t\t\t};",
    "\t\t\t}",
  ].join("\n");
}

const betterSidebarClient = [
  "window.__ModuleLoader__.load({",
  '\tid: "dsh-better-sidebar",',
  "\tfactory: () => {",
  "\t\tconst FAILURE_LIMIT = 3;",
  betterSidebarSocketEffect("agent-terminals"),
  betterSidebarSocketEffect("agent-opens"),
  "\t}",
  "});",
].join("\n");
const rewrittenBetterSidebar = rewriteBetterSidebarWebSocketResilience(betterSidebarClient);
assert.match(rewrittenBetterSidebar, new RegExp(BETTER_SIDEBAR_WS_MARKER));
assert.equal(rewrittenBetterSidebar.match(/socket\.onopen = \(\) =>/g)?.length, 2);
assert.equal(rewrittenBetterSidebar.match(/failures = 0;/g)?.length, 4);
assert.equal(rewrittenBetterSidebar.match(/socket\.send\("ping"\)/g)?.length, 2);
assert.equal(rewrittenBetterSidebar.match(/window\.clearInterval\(keepAlive\)/g)?.length, 6);
assert.equal(rewriteBetterSidebarWebSocketResilience(rewrittenBetterSidebar), rewrittenBetterSidebar);
new vm.Script(rewrittenBetterSidebar);
for (const marker of BETTER_SIDEBAR_CONTAINER_MARKERS) {
  const registryClient = betterSidebarClient.replace('id: "dsh-better-sidebar"', marker);
  assert.match(rewriteBetterSidebarWebSocketResilience(registryClient), /socket\.send\("ping"\)/);
}
const unknownSidebarClient = betterSidebarClient.replace(
  'id: "dsh-better-sidebar"',
  'id: "dsh-example-sidebar"',
);
assert.equal(rewriteBetterSidebarWebSocketResilience(unknownSidebarClient), unknownSidebarClient);
const incompleteSidebarClient = betterSidebarClient.replace(
  "/sidebar/ws/agent-opens",
  "/sidebar/ws/unknown",
);
assert.equal(rewriteBetterSidebarWebSocketResilience(incompleteSidebarClient), incompleteSidebarClient);
for (const route of BETTER_SIDEBAR_CLIENT_ROUTES) {
  assert.equal(isAdaptedPluginClientPath(`/plugins/${route}`), true);
}

const mobileUiClient = [
  "window.__ModuleLoader__.load({",
  "  id: '@deepseek-ai/dsh-mobile-ui',",
  "  factory: () => {",
  "    const viewportEvent = 'mobile-viewport/change';",
  "    const bottomNav = 'mobile-bottom-nav';",
  "    const rootAttribute = 'data-dsh-mobile';",
  "    return { viewportEvent, bottomNav, rootAttribute };",
  "  },",
  "});",
].join("\n");
const officialClient = [
  "window.__ModuleLoader__.load({",
  "  id: '@deepseek-ai/dsh-typert-registry',",
  "  factory: () => ({ official: true }),",
  "});",
].join("\n");
const mobileUiCombinedBundle = `${officialClient}\n${mobileUiClient}`;
const rewrittenMobileUi = rewriteMobileUiRegistration(mobileUiCombinedBundle);
assert.match(rewrittenMobileUi, /id: 'dsh-mobile-ui'/);
assert.doesNotMatch(rewrittenMobileUi, /id: '@deepseek-ai\/dsh-mobile-ui'/);
assert.match(rewrittenMobileUi, /id: '@deepseek-ai\/dsh-typert-registry'/);
assert.equal(rewriteMobileUiRegistration(rewrittenMobileUi), rewrittenMobileUi);
const mobileRegistrations = [];
vm.runInNewContext(rewrittenMobileUi, {
  window: { __ModuleLoader__: { load: (registration) => mobileRegistrations.push(registration.id) } },
});
assert.deepEqual(mobileRegistrations, ["@deepseek-ai/dsh-typert-registry", "dsh-mobile-ui"]);
for (const [index, marker] of MOBILE_UI_MARKERS.entries()) {
  const incompleteMobileUi = mobileUiClient.replace(marker, `missing-mobile-marker-${index}`);
  assert.equal(rewriteMobileUiRegistration(incompleteMobileUi), incompleteMobileUi);
}
const correctlyNamedMobileUi = mobileUiClient.replace(
  "id: '@deepseek-ai/dsh-mobile-ui'",
  "id: 'dsh-mobile-ui'",
);
assert.equal(rewriteMobileUiRegistration(correctlyNamedMobileUi), correctlyNamedMobileUi);
const ambiguousMobileUi = `${mobileUiClient}\n${mobileUiClient}`;
assert.equal(rewriteMobileUiRegistration(ambiguousMobileUi).match(/id: 'dsh-mobile-ui'/g)?.length, 2);

const sidebarClient = [
  'fetch(`/sidebar/api/fs.list`)',
  'const chunk = "/sidebar/bundle/editor.js";',
  'const file = "/sidebar/file?sessionId=test";',
  'const html = "/sidebar/html/session/work/index.html";',
  'const terminal = new URL("/sidebar/ws/terminal", location.origin);',
].join("\n");
assert.equal(rewriteBody(sidebarClient, prefix), sidebarClient);
const rewrittenSidebarClient = rewriteBody(sidebarClient, prefix, ["/sidebar/"]);
for (const route of [
  "/sidebar/api/fs.list",
  "/sidebar/bundle/editor.js",
  "/sidebar/file?sessionId=test",
  "/sidebar/html/session/work/index.html",
  "/sidebar/ws/terminal",
]) {
  assert.ok(rewrittenSidebarClient.includes(`${prefix}${route}`));
}
assert.equal(rewriteBody(rewrittenSidebarClient, prefix), rewrittenSidebarClient);
assert.match(runtimeAdapterScript(prefix, ["/sidebar/"]), /XMLHttpRequest/);
assert.match(runtimeAdapterScript(prefix, ["/sidebar/"]), /WebSocket/);

const remoteMuxClient = [
  'const REMOTE_STREAM_MUX_PATH = "/api/remote.mux";',
  "const url = new URL(REMOTE_STREAM_MUX_PATH.slice(1), document.baseURI);",
].join("\n");
const rewrittenRemoteMuxClient = rewriteBody(remoteMuxClient, prefix);
assert.ok(rewrittenRemoteMuxClient.includes('REMOTE_STREAM_MUX_PATH = "/api/remote.mux"'));
assert.ok(!rewrittenRemoteMuxClient.includes(`${prefix}/api/remote.mux`));
const remoteMuxPath = /REMOTE_STREAM_MUX_PATH = "([^"]+)"/.exec(rewrittenRemoteMuxClient)?.[1];
assert.equal(
  new URL(remoteMuxPath.slice(1), `https://nas.test${prefix}/`).pathname,
  `${prefix}/api/remote.mux`,
);
assert.equal(rewriteBody(rewrittenRemoteMuxClient, prefix), rewrittenRemoteMuxClient);

const openedSockets = [];
const fetchedUrls = [];
function NativeWebSocket(url) {
  openedSockets.push(String(url));
}
const adapterWindow = {
  location: {
    href: "https://nas.test/app/deepseek-harness/",
    host: "nas.test",
    origin: "https://nas.test",
    protocol: "https:",
  },
  fetch(input) {
    fetchedUrls.push(String(input));
    return Promise.resolve({ ok: true });
  },
  WebSocket: NativeWebSocket,
};
vm.runInNewContext(runtimeAdapterScript(prefix, ["/sidebar/"]), {
  URL,
  WebSocket: NativeWebSocket,
  window: adapterWindow,
});
adapterWindow.fetch(new URL("https://nas.test/api/llm/listProviders"));
adapterWindow.fetch(new URL(`https://nas.test${prefix}/api/llm/listProviders`));
adapterWindow.fetch("https://external.test/api/llm/listProviders");
new adapterWindow.WebSocket("wss://nas.test/sidebar/ws/terminal");
new adapterWindow.WebSocket("wss://external.test/sidebar/ws/terminal");
new adapterWindow.WebSocket(`wss://nas.test${prefix}${prefix}/api/remote.mux`);
assert.deepEqual(fetchedUrls, [
  `https://nas.test${prefix}/api/llm/listProviders`,
  `https://nas.test${prefix}/api/llm/listProviders`,
  "https://external.test/api/llm/listProviders",
]);
assert.deepEqual(openedSockets, [
  `wss://nas.test${prefix}/sidebar/ws/terminal`,
  "wss://external.test/sidebar/ws/terminal",
  `wss://nas.test${prefix}/api/remote.mux`,
]);

const unrelatedUrls =
  'const external = "https://example.test/sidebar/api/fs.list"; const plural = "/sidebars/api";';
assert.equal(rewriteBody(unrelatedUrls, prefix), unrelatedUrls);

assert.equal(rewriteLocation("/api/login", prefix), `${prefix}/api/login`);
assert.equal(rewriteLocation("/sidebar/file", prefix), "/sidebar/file");
assert.equal(rewriteLocation("/sidebar/file", prefix, ["/sidebar/"]), `${prefix}/sidebar/file`);
assert.equal(rewriteLocation("/third-party/path", prefix), "/third-party/path");
assert.equal(rewriteLocation("https://example.test/", prefix), "https://example.test/");
assert.equal(rewriteSetCookie("sid=x; Path=/; HttpOnly", prefix), `sid=x; Path=${prefix}/; HttpOnly`);

const registryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gateway-proxy-registry-test-"));
try {
  const registryPath = path.join(registryRoot, "gateway-compat.json");
  const profilesRoot = path.join(registryRoot, "profiles");
  const webProfile = path.join(profilesRoot, "web");
  assert.deepEqual(readDynamicPrefixes(registryPath, "web", profilesRoot), []);

  const sidebarPackage = path.join(webProfile, "node_modules", "dsh-better-sidebar");
  fs.mkdirSync(sidebarPackage, { recursive: true });
  fs.writeFileSync(path.join(webProfile, "package.json"), JSON.stringify({
    dependencies: { "dsh-better-sidebar": "0.12.2" },
  }));
  assert.deepEqual(readDynamicPrefixes(registryPath, "web", profilesRoot), []);

  fs.writeFileSync(path.join(sidebarPackage, "package.json"), JSON.stringify({ name: "dsh-better-sidebar" }));
  assert.deepEqual(readDynamicPrefixes(registryPath, "web", profilesRoot), ["/sidebar/"]);

  fs.writeFileSync(path.join(sidebarPackage, "package.json"), JSON.stringify({ name: "different-package" }));
  assert.deepEqual(readDynamicPrefixes(registryPath, "web", profilesRoot), []);
  fs.writeFileSync(path.join(sidebarPackage, "package.json"), JSON.stringify({ name: "dsh-better-sidebar" }));

  writeRegistry(
    registryPath,
    setPlugin(emptyRegistry(), "web", "manual-plugin", "1.0.0", ["/editor/"], "approved"),
  );
  assert.deepEqual(readDynamicPrefixes(registryPath, "web", profilesRoot), ["/editor/", "/sidebar/"]);
} finally {
  fs.rmSync(registryRoot, { recursive: true, force: true });
}

function listen(server, ...args) {
  return new Promise((resolve, reject) => {
    const fail = (error) => reject(error);
    server.once("error", fail);
    server.listen(...args, () => {
      server.off("error", fail);
      resolve();
    });
  });
}

function close(server) {
  if (!server || !server.listening) return Promise.resolve();
  return new Promise((resolve) => server.close(resolve));
}

function requestGateway(socketPath, headers, requestPath = "/probe") {
  return new Promise((resolve, reject) => {
    const request = http.request(
      { socketPath, method: "GET", path: `${prefix}${requestPath}`, headers },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => resolve({
          status: response.statusCode,
          headers: response.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        }));
      },
    );
    request.on("error", reject);
    request.end();
  });
}

function requestGatewayUpgrade(socketPath, headers) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath,
      method: "GET",
      path: `${prefix}/socket`,
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-key": "dGVzdC1nYXRld2F5LWtleQ==",
        "sec-websocket-version": "13",
        ...headers,
      },
    });
    request.on("upgrade", (response, socket) => {
      socket.destroy();
      resolve(response.statusCode);
    });
    request.on("response", (response) => {
      response.resume();
      response.on("end", () => resolve(response.statusCode));
    });
    request.on("error", reject);
    request.end();
  });
}

async function testGatewayUpgradeForwardsClientBytesOnce() {
  const observed = [];
  let resolveFirstChunk;
  const firstChunk = new Promise((resolve) => {
    resolveFirstChunk = resolve;
  });
  const backend = http.createServer((_request, response) => {
    response.writeHead(404);
    response.end();
  });
  let backendSocket;
  backend.on("upgrade", (_request, socket, head) => {
    backendSocket = socket;
    if (head.length) {
      observed.push(Buffer.from(head));
      resolveFirstChunk();
    }
    socket.on("data", (chunk) => {
      observed.push(Buffer.from(chunk));
      resolveFirstChunk();
    });
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Connection: Upgrade\r\n" +
      "Upgrade: websocket\r\n\r\n",
    );
  });

  const socketPath = process.platform === "win32"
    ? `\\\\.\\pipe\\dsh-gateway-upgrade-once-${process.pid}-${Date.now()}`
    : path.join(os.tmpdir(), `dsh-gateway-upgrade-once-${process.pid}-${Date.now()}.sock`);
  let gateway;
  let clientSocket;
  try {
    await listen(backend, 0, "127.0.0.1");
    gateway = startGatewayProxy({
      socketPath,
      gatewayPrefix: prefix,
      target: { host: "127.0.0.1", port: backend.address().port },
    });
    await once(gateway, "listening");

    clientSocket = await new Promise((resolve, reject) => {
      const request = http.request({
        socketPath,
        method: "GET",
        path: `${prefix}/socket`,
        headers: {
          connection: "Upgrade",
          upgrade: "websocket",
          "sec-websocket-key": "dGVzdC1nYXRld2F5LWtleQ==",
          "sec-websocket-version": "13",
          "x-trim-isadmin": "true",
        },
      });
      request.on("upgrade", (response, socket) => {
        assert.equal(response.statusCode, 101);
        socket.on("error", () => {});
        resolve(socket);
      });
      request.on("response", (response) => {
        response.resume();
        reject(new Error(`unexpected upgrade response: ${response.statusCode}`));
      });
      request.on("error", reject);
      request.end();
    });

    const frame = Buffer.from([0x81, 0x81, 0x01, 0x02, 0x03, 0x04, 0x79]);
    clientSocket.write(frame);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("timed out waiting for the forwarded WebSocket frame")),
        1000,
      );
      firstChunk.then(() => {
        clearTimeout(timer);
        resolve();
      }, reject);
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.deepEqual(Buffer.concat(observed), frame);
  } finally {
    if (clientSocket) clientSocket.destroy();
    if (backendSocket) backendSocket.destroy();
    await close(gateway);
    await close(backend);
    if (process.platform !== "win32") fs.rmSync(socketPath, { force: true });
  }
}

async function testGatewayAuthorization() {
  let pluginRequestHeaders;
  let betterSidebarRequestHeaders;
  let mobileUiRequestHeaders;
  const backend = http.createServer((request, response) => {
    if (request.url === "/plugins/@linxin666/dsh-remote-web-ui/client.js") {
      pluginRequestHeaders = request.headers;
      if (request.headers["if-none-match"] || request.headers["if-modified-since"]) {
        response.writeHead(304);
        response.end();
        return;
      }
      response.writeHead(200, {
        "content-type": "application/javascript; charset=utf-8",
        "cache-control": "public, max-age=86400",
        etag: '"upstream-plugin"',
        "last-modified": "Sat, 22 Aug 2026 00:00:00 GMT",
        expires: "Sun, 23 Aug 2026 00:00:00 GMT",
        age: "120",
      });
      response.end(remoteWebUiBundle);
      return;
    }
    if (request.url === "/plugins/dsh-better-sidebar/client.js") {
      betterSidebarRequestHeaders = request.headers;
      if (request.headers["if-none-match"] || request.headers["if-modified-since"]) {
        response.writeHead(304);
        response.end();
        return;
      }
      response.writeHead(200, {
        "content-type": "application/javascript; charset=utf-8",
        "cache-control": "public, max-age=86400",
        etag: '"upstream-better-sidebar"',
        "last-modified": "Sat, 22 Aug 2026 00:00:00 GMT",
      });
      response.end(betterSidebarClient);
      return;
    }
    if (request.url === "/plugins/??@deepseek-ai/dsh-typert-registry/client.js,dsh-mobile-ui/client.js&rev=mobile") {
      mobileUiRequestHeaders = request.headers;
      if (request.headers["if-none-match"] || request.headers["if-modified-since"]) {
        response.writeHead(304);
        response.end();
        return;
      }
      response.writeHead(200, {
        "content-type": "application/javascript; charset=utf-8",
        "cache-control": "public, max-age=86400",
        etag: '"upstream-mobile-ui"',
        "last-modified": "Sat, 22 Aug 2026 00:00:00 GMT",
      });
      response.end(mobileUiCombinedBundle);
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      path: request.url,
      fetchSite: request.headers["sec-fetch-site"],
      forwardedAdmin: request.headers["x-trim-isadmin"],
    }));
  });
  backend.on("upgrade", (_request, socket) => {
    socket.end(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Connection: Upgrade\r\n" +
      "Upgrade: websocket\r\n\r\n",
    );
  });

  const socketPath = process.platform === "win32"
    ? `\\\\.\\pipe\\dsh-gateway-test-${process.pid}-${Date.now()}`
    : path.join(os.tmpdir(), `dsh-gateway-test-${process.pid}-${Date.now()}.sock`);
  let gateway;
  try {
    await listen(backend, 0, "127.0.0.1");
    const address = backend.address();
    gateway = startGatewayProxy({
      socketPath,
      gatewayPrefix: prefix,
      target: { host: "127.0.0.1", port: address.port },
    });
    await once(gateway, "listening");

    const denied = await requestGateway(socketPath, { "x-trim-isadmin": "false" });
    assert.equal(denied.status, 403);
    assert.match(denied.body, /Administrator access is required/);

    const allowed = await requestGateway(socketPath, { "x-trim-isadmin": "true" });
    assert.equal(allowed.status, 200);
    assert.deepEqual(JSON.parse(allowed.body), {
      path: "/probe",
      fetchSite: "same-origin",
    });

    const rewrittenPlugin = await requestGateway(
      socketPath,
      {
        "x-trim-isadmin": "true",
        "if-none-match": '"upstream-plugin"',
        "if-modified-since": "Sat, 22 Aug 2026 00:00:00 GMT",
      },
      "/plugins/@linxin666/dsh-remote-web-ui/client.js",
    );
    assert.equal(rewrittenPlugin.status, 200);
    assert.equal(pluginRequestHeaders["if-none-match"], undefined);
    assert.equal(pluginRequestHeaders["if-modified-since"], undefined);
    assert.match(rewrittenPlugin.body, /const loopback = true;/);
    assert.equal(rewrittenPlugin.headers.etag, undefined);
    assert.equal(rewrittenPlugin.headers["last-modified"], undefined);
    assert.equal(rewrittenPlugin.headers.expires, undefined);
    assert.equal(rewrittenPlugin.headers.age, undefined);
    assert.equal(rewrittenPlugin.headers["cache-control"], "no-store");

    const rewrittenBetterSidebarResponse = await requestGateway(
      socketPath,
      {
        "x-trim-isadmin": "true",
        "if-none-match": '"upstream-better-sidebar"',
        "if-modified-since": "Sat, 22 Aug 2026 00:00:00 GMT",
      },
      "/plugins/dsh-better-sidebar/client.js",
    );
    assert.equal(rewrittenBetterSidebarResponse.status, 200);
    assert.equal(betterSidebarRequestHeaders["if-none-match"], undefined);
    assert.equal(betterSidebarRequestHeaders["if-modified-since"], undefined);
    assert.match(rewrittenBetterSidebarResponse.body, new RegExp(BETTER_SIDEBAR_WS_MARKER));
    assert.equal(rewrittenBetterSidebarResponse.body.match(/socket\.send\("ping"\)/g)?.length, 2);
    assert.equal(rewrittenBetterSidebarResponse.headers.etag, undefined);
    assert.equal(rewrittenBetterSidebarResponse.headers["last-modified"], undefined);
    assert.equal(rewrittenBetterSidebarResponse.headers["cache-control"], "no-store");

    const rewrittenMobileUiResponse = await requestGateway(
      socketPath,
      {
        "x-trim-isadmin": "true",
        "if-none-match": '"upstream-mobile-ui"',
        "if-modified-since": "Sat, 22 Aug 2026 00:00:00 GMT",
      },
      "/plugins/??@deepseek-ai/dsh-typert-registry/client.js,dsh-mobile-ui/client.js&rev=mobile",
    );
    assert.equal(rewrittenMobileUiResponse.status, 200);
    assert.equal(mobileUiRequestHeaders["if-none-match"], undefined);
    assert.equal(mobileUiRequestHeaders["if-modified-since"], undefined);
    assert.match(rewrittenMobileUiResponse.body, /id: 'dsh-mobile-ui'/);
    assert.doesNotMatch(rewrittenMobileUiResponse.body, /id: '@deepseek-ai\/dsh-mobile-ui'/);
    assert.match(rewrittenMobileUiResponse.body, /id: '@deepseek-ai\/dsh-typert-registry'/);
    assert.equal(rewrittenMobileUiResponse.headers.etag, undefined);
    assert.equal(rewrittenMobileUiResponse.headers["last-modified"], undefined);
    assert.equal(rewrittenMobileUiResponse.headers["cache-control"], "no-store");

    assert.equal(await requestGatewayUpgrade(socketPath, { "x-trim-isadmin": "false" }), 403);
    assert.equal(await requestGatewayUpgrade(socketPath, { "x-trim-isadmin": "true" }), 101);
  } finally {
    await close(gateway);
    await close(backend);
    if (process.platform !== "win32") fs.rmSync(socketPath, { force: true });
  }
}

async function testGatewayBrowserAuthentication() {
  const launchToken = "a".repeat(43);
  const tokenRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gateway-auth-token-test-"));
  const tokenPath = path.join(tokenRoot, "web-auth.token");
  fs.writeFileSync(tokenPath, `${launchToken}\n`, { mode: 0o600 });
  if (process.platform !== "win32") fs.chmodSync(tokenPath, 0o600);

  let authCookieName;
  const backendRequests = [];
  const backend = http.createServer((request, response) => {
    backendRequests.push({ url: request.url, cookie: request.headers.cookie });
    const url = new URL(request.url || "/", "http://backend.test");
    if (url.pathname === "/" && url.searchParams.get("token") === launchToken) {
      response.writeHead(303, {
        location: "/",
        "cache-control": "no-store",
        "set-cookie": `${authCookieName}=signed-session; Path=/; HttpOnly; SameSite=Strict`,
      });
      response.end();
      return;
    }
    if (request.headers.cookie === `${authCookieName}=signed-session`) {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end("<html><head></head><body>authenticated</body></html>");
      return;
    }
    response.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
    response.end("authentication required\n");
  });
  backend.on("upgrade", (request, socket) => {
    if (request.headers.cookie !== `${authCookieName}=signed-session`) {
      socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      return;
    }
    socket.end(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Connection: Upgrade\r\n" +
      "Upgrade: websocket\r\n\r\n",
    );
  });

  const socketPath = process.platform === "win32"
    ? `\\\\.\\pipe\\dsh-gateway-auth-test-${process.pid}-${Date.now()}`
    : path.join(os.tmpdir(), `dsh-gateway-auth-test-${process.pid}-${Date.now()}.sock`);
  let gateway;
  try {
    await listen(backend, 0, "127.0.0.1");
    const address = backend.address();
    const authTarget = { host: "127.0.0.1", port: address.port };
    authCookieName = backendAuthCookieName(authTarget);
    gateway = startGatewayProxy({
      socketPath,
      gatewayPrefix: prefix,
      target: authTarget,
      authTokenPath: tokenPath,
    });
    await once(gateway, "listening");

    const denied = await requestGateway(socketPath, { "x-trim-isadmin": "false" }, "/");
    assert.equal(denied.status, 403);
    assert.equal(backendRequests.length, 0);

    const exchange = await requestGateway(
      socketPath,
      { "x-trim-isadmin": "true" },
      "/?token=browser-supplied-token",
    );
    assert.equal(exchange.status, 303);
    assert.equal(exchange.headers.location, `${prefix}/`);
    const setCookie = exchange.headers["set-cookie"];
    assert.ok(Array.isArray(setCookie));
    assert.match(setCookie[0], new RegExp(`^${authCookieName}=signed-session;`));
    assert.match(setCookie[0], new RegExp(`Path=${prefix}/`));
    assert.doesNotMatch(JSON.stringify(exchange), /browser-supplied-token/);
    assert.ok(!JSON.stringify(exchange).includes(launchToken));
    assert.ok(backendRequests[0].url.includes(`token=${launchToken}`));
    assert.ok(!backendRequests[0].url.includes("browser-supplied-token"));

    const browserCookie = setCookie[0].split(";", 1)[0];
    const authenticated = await requestGateway(
      socketPath,
      { "x-trim-isadmin": "true", cookie: browserCookie },
      "/",
    );
    assert.equal(authenticated.status, 200);
    assert.match(authenticated.body, /authenticated/);
    assert.equal(backendRequests.at(-1).url, "/");
    assert.equal(backendRequests.at(-1).cookie, browserCookie);

    const serverAuthenticated = await requestGateway(
      socketPath,
      { "x-trim-isadmin": "true", cookie: "dsh-auth-stale=old-session" },
      "/probe",
    );
    assert.equal(serverAuthenticated.status, 200);
    assert.match(serverAuthenticated.body, /authenticated/);
    assert.equal(backendRequests.at(-1).url, "/probe");
    assert.equal(backendRequests.at(-1).cookie, browserCookie);

    assert.equal(
      await requestGatewayUpgrade(socketPath, { "x-trim-isadmin": "true", cookie: browserCookie }),
      101,
    );
    assert.equal(
      await requestGatewayUpgrade(socketPath, { "x-trim-isadmin": "true", cookie: "dsh-auth-stale=old-session" }),
      101,
    );

    const beforeRecovery = backendRequests.length;
    const recovered = await requestGateway(
      socketPath,
      { "x-trim-isadmin": "true", cookie: `${authCookieName}=invalid` },
      "/",
    );
    assert.equal(recovered.status, 303);
    assert.equal(backendRequests[beforeRecovery].url, "/");
    assert.ok(backendRequests[beforeRecovery + 1].url.includes(`token=${launchToken}`));
    assert.ok(!JSON.stringify(recovered).includes(launchToken));
  } finally {
    await close(gateway);
    await close(backend);
    if (process.platform !== "win32") fs.rmSync(socketPath, { force: true });
    fs.rmSync(tokenRoot, { recursive: true, force: true });
  }
}

async function testGatewayAuthResilience() {
  const launchToken = "b".repeat(43);
  const rotatedToken = "c".repeat(43);
  const tokenRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gateway-auth-resilience-"));
  const tokenPath = path.join(tokenRoot, "web-auth.token");
  fs.writeFileSync(tokenPath, `${launchToken}\n`, { mode: 0o600 });
  if (process.platform !== "win32") fs.chmodSync(tokenPath, 0o600);

  let authCookieName;
  let sessionEpoch = 0;
  let validCookie;
  const backendRequests = [];
  const backend = http.createServer((request, response) => {
    backendRequests.push({ url: request.url, cookie: request.headers.cookie });
    const url = new URL(request.url || "/", "http://backend.test");
    if (url.pathname === "/" && url.searchParams.has("token")) {
      const presented = url.searchParams.get("token");
      const accepted = presented === launchToken || presented === rotatedToken;
      if (!accepted) {
        response.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
        response.end("invalid launch token\n");
        return;
      }
      sessionEpoch += 1;
      validCookie = `session-${sessionEpoch}`;
      response.writeHead(303, {
        location: "/",
        "cache-control": "no-store",
        "set-cookie": `${authCookieName}=${validCookie}; Path=/; HttpOnly; SameSite=Strict`,
      });
      response.end();
      return;
    }
    if (request.headers.cookie === `${authCookieName}=${validCookie}`) {
      response.writeHead(200, { "content-type": "application/json" });
      response.end("{}");
      return;
    }
    response.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
    response.end("authentication required\n");
  });
  backend.on("upgrade", (request, socket) => {
    backendRequests.push({ url: request.url, cookie: request.headers.cookie, upgrade: true });
    if (request.headers.cookie !== `${authCookieName}=${validCookie}`) {
      socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      return;
    }
    socket.end(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Connection: Upgrade\r\n" +
      "Upgrade: websocket\r\n\r\n",
    );
  });

  const socketPath = path.join(
    os.tmpdir(),
    `dsh-gateway-resilience-${process.pid}-${Date.now()}.sock`,
  );
  let gateway;
  try {
    await listen(backend, 0, "127.0.0.1");
    const address = backend.address();
    const authTarget = { host: "127.0.0.1", port: address.port };
    authCookieName = backendAuthCookieName(authTarget);
    gateway = startGatewayProxy({
      socketPath,
      gatewayPrefix: prefix,
      target: authTarget,
      authTokenPath: tokenPath,
    });
    await once(gateway, "listening");

    // Unrelated app cookies survive the gateway auth merge; all dsh-auth-*
    // variants are stripped so exactly one signed cookie reaches upstream.
    assert.equal(
      mergeBackendAuthCookie("app=1; dsh-auth-stale=old; other=2", authCookieName, `${authCookieName}=fresh`),
      `app=1; other=2; ${authCookieName}=fresh`,
    );
    assert.equal(mergeBackendAuthCookie(undefined, authCookieName, `${authCookieName}=fresh`), `${authCookieName}=fresh`);

    // First non-root request acquires and injects the server-side session.
    const first = await requestGateway(socketPath, { "x-trim-isadmin": "true" }, "/api/one");
    assert.equal(first.status, 200);
    assert.ok(backendRequests[0].url.includes(`token=${launchToken}`));
    assert.equal(backendRequests[1].cookie, `${authCookieName}=session-1`);

    // Backend session rotation invalidates the cached cookie: a replayed
    // non-root GET transparently refreshes and succeeds.
    validCookie = "rotated-out";
    const recovered = await requestGateway(socketPath, { "x-trim-isadmin": "true" }, "/api/two");
    assert.equal(recovered.status, 200);
    // Attempt 1 carries the stale cached session, then a refresh exchange,
    // then the replay with the fresh session.
    assert.equal(backendRequests[2].cookie, `${authCookieName}=session-1`);
    assert.ok(backendRequests[3].url.includes(`token=${launchToken}`));
    assert.equal(backendRequests[4].cookie, `${authCookieName}=session-2`);

    // A rotated launch-token file is picked up on refresh without a restart.
    validCookie = "rotated-out-again";
    fs.writeFileSync(tokenPath, `${rotatedToken}\n`, { mode: 0o600 });
    if (process.platform !== "win32") fs.chmodSync(tokenPath, 0o600);
    const afterRotation = await requestGateway(socketPath, { "x-trim-isadmin": "true" }, "/api/three");
    assert.equal(afterRotation.status, 200);
    assert.ok(backendRequests[6].url.includes(`token=${rotatedToken}`));

    // WebSocket handshake with a stale cached session refreshes and connects.
    validCookie = "ws-rotated-out";
    assert.equal(
      await requestGatewayUpgrade(socketPath, { "x-trim-isadmin": "true" }),
      101,
    );
    const upgradeAttempts = backendRequests.filter((entry) => entry.upgrade);
    assert.equal(upgradeAttempts.length, 2);
    // First attempt carries the stale cached session, retry the fresh one.
    assert.match(upgradeAttempts[0].cookie, new RegExp(`^${authCookieName}=session-\\d+$`));
    assert.match(upgradeAttempts[1].cookie, new RegExp(`^${authCookieName}=session-\\d+$`));
    assert.notEqual(upgradeAttempts[0].cookie, upgradeAttempts[1].cookie);

    // Exchange timeout surfaces as an error instead of hanging forever.
    const hungBackend = http.createServer(() => { /* never responds */ });
    await listen(hungBackend, 0, "127.0.0.1");
    const hungTarget = { host: "127.0.0.1", port: hungBackend.address().port };
    const hungName = backendAuthCookieName(hungTarget);
    await assert.rejects(
      requestBackendAuthCookie(hungTarget, launchToken, hungName, 200),
      /timed out/,
    );
    await close(hungBackend);
  } finally {
    await close(gateway);
    await close(backend);
    if (process.platform !== "win32") fs.rmSync(socketPath, { force: true });
    fs.rmSync(tokenRoot, { recursive: true, force: true });
  }
}

async function testFnosExportHelpers() {
  assert.equal(FNOS_OPEN_ENHANCER_PATH, "/__fnos/fnos-open.js");
  assert.equal(TRIM_WEB_APP_PATH, "/__fnos/trim-web-app.js");
  assert.equal(EXPORT_OPEN_PATH, "/__fnos/export-open");
  assert.equal(SESSION_EXPORT_PATH, "/__fnos/export-session");
  assert.equal(EXPORT_DIR_NAME, "dsh-exports");
  assert.deepEqual(validateSessionExportPayload({ sessionId: "session-123" }), {
    sessionId: "session-123",
    includeDescendants: true,
  });
  assert.deepEqual(validateSessionExportPayload({
    sessionId: "session-123",
    includeDescendants: false,
  }), {
    sessionId: "session-123",
    includeDescendants: false,
  });
  assert.throws(
    () => validateSessionExportPayload({ sessionId: "../private" }),
    (error) => error.statusCode === 400,
  );
  assert.throws(
    () => validateSessionExportPayload({ sessionId: "session-123", includeDescendants: "true" }),
    (error) => error.statusCode === 400,
  );

  assert.equal(sanitizeExportBasename("report.pdf"), "report.pdf");
  assert.equal(sanitizeExportBasename("../etc/passwd"), "passwd");
  assert.equal(sanitizeExportBasename("a/b/c.txt"), "c.txt");
  assert.equal(sanitizeExportBasename("a\\b\\c.txt"), "c.txt");
  assert.equal(sanitizeExportBasename("季度 报告?.md"), "季度_报告_.md");
  assert.equal(sanitizeExportBasename(".hidden"), "hidden");
  assert.equal(sanitizeExportBasename(""), "file");
  assert.equal(sanitizeExportBasename(".."), "file");

  assert.deepEqual(readFnosEnvConfig({}), {
    visibleRoots: [],
    workspaceRoot: null,
    homeRoot: null,
  });
  assert.deepEqual(
    readFnosEnvConfig({ TRIM_DATA_SHARE_PATHS: "/nonexistent-a:/nonexistent-b" }).visibleRoots,
    [],
  );
  assert.deepEqual(
    readFnosEnvConfig({ TRIM_DATA_ACCESSIBLE_PATHS: __dirname }).visibleRoots,
    [fs.realpathSync(__dirname)],
  );
    const envTmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fnos-env-unit-"));
    const packageHome = fs.mkdtempSync(path.join(os.tmpdir(), "fnos-package-home-"));
    const packageVar = fs.mkdtempSync(path.join(os.tmpdir(), "fnos-package-var-"));
    try {
      fs.mkdirSync(path.join(packageHome, ".dsh"));
    assert.equal(
      readFnosEnvConfig({ DSH_HOME: envTmpRoot }).homeRoot,
      fs.realpathSync(envTmpRoot),
    );
    assert.equal(
      readFnosEnvConfig({ TRIM_PKGHOME: packageHome, DSH_HOME: envTmpRoot }).homeRoot,
      fs.realpathSync(path.join(packageHome, ".dsh")),
    );
    assert.deepEqual(
      readFnosEnvConfig({ TRIM_PKGHOME: packageHome, TRIM_PKGVAR: packageVar }).visibleRoots,
      [fs.realpathSync(packageVar), fs.realpathSync(packageHome)],
    );
    if (process.platform !== "win32") {
      const shareA = fs.mkdtempSync(path.join(os.tmpdir(), "fnos-share-a-"));
      const shareB = fs.mkdtempSync(path.join(os.tmpdir(), "fnos-share-b-"));
      const accessibleRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fnos-accessible-"));
      try {
        const splitConfig = readFnosEnvConfig({
          TRIM_DATA_SHARE_PATHS: `${shareA}:${shareB}`,
          TRIM_DATA_ACCESSIBLE_PATHS: `${accessibleRoot}:${shareA}`,
          TRIM_PKGVAR: packageVar,
          TRIM_PKGHOME: packageHome,
        });
        assert.deepEqual(splitConfig.visibleRoots, [
          fs.realpathSync(shareA),
          fs.realpathSync(shareB),
          fs.realpathSync(accessibleRoot),
          fs.realpathSync(packageVar),
          fs.realpathSync(packageHome),
        ]);
        assert.equal(splitConfig.workspaceRoot, fs.realpathSync(shareA));
      } finally {
        fs.rmSync(shareA, { recursive: true, force: true });
        fs.rmSync(shareB, { recursive: true, force: true });
        fs.rmSync(accessibleRoot, { recursive: true, force: true });
      }
    }
  } finally {
    fs.rmSync(envTmpRoot, { recursive: true, force: true });
    fs.rmSync(packageHome, { recursive: true, force: true });
    fs.rmSync(packageVar, { recursive: true, force: true });
  }

  const unitRoot = path.join(os.tmpdir(), "fnos-within-root");
  assert.equal(isPathWithinRoot(unitRoot, path.join(unitRoot, "file.txt")), true);
  assert.equal(isPathWithinRoot(unitRoot, path.join(unitRoot, "sub", "file.txt")), true);
  assert.equal(isPathWithinRoot(unitRoot, unitRoot), false);
  assert.equal(isPathWithinRoot(unitRoot, path.join(unitRoot, "..", "sibling.txt")), false);
  assert.equal(
    isPathWithinRoot(unitRoot, path.join(path.dirname(unitRoot), "other.txt")),
    false,
  );

  const helperRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fnos-export-unit-"));
  try {
    const allowedRoot = path.join(helperRoot, "home");
    const outsideRoot = path.join(helperRoot, "outside");
    const workspaceRoot = path.join(helperRoot, "workspace");
    fs.mkdirSync(path.join(allowedRoot, "dir"), { recursive: true });
    fs.mkdirSync(outsideRoot, { recursive: true });
    fs.mkdirSync(workspaceRoot, { recursive: true });
    fs.writeFileSync(path.join(allowedRoot, "report.txt"), "payload");
    fs.writeFileSync(path.join(allowedRoot, "dir", "nested.txt"), "nested");
    fs.writeFileSync(path.join(outsideRoot, "secret.txt"), "secret");
    const unitConfig = {
      visibleRoots: [fs.realpathSync(allowedRoot)],
      workspaceRoot: fs.realpathSync(workspaceRoot),
      homeRoot: fs.realpathSync(allowedRoot),
    };

    assert.equal(
      resolveExportSource(path.join(allowedRoot, "report.txt"), unitConfig),
      fs.realpathSync(path.join(allowedRoot, "report.txt")),
    );
    assert.throws(
      () => resolveExportSource(path.join(outsideRoot, "secret.txt"), unitConfig),
      (error) => error.statusCode === 403,
    );
    assert.throws(
      () => resolveExportSource(
        path.join(allowedRoot, "..", "outside", "secret.txt"),
        unitConfig,
      ),
      (error) => error.statusCode === 403,
    );
    assert.throws(
      () => resolveExportSource(path.join(allowedRoot, "missing.txt"), unitConfig),
      (error) => error.statusCode === 404,
    );
    assert.throws(
      () => resolveExportSource(allowedRoot, unitConfig),
      (error) => error.statusCode === 400,
    );
    assert.throws(
      () => resolveExportSource("relative/path.txt", unitConfig),
      (error) => error.statusCode === 400,
    );

    const destination = pickExportDestination(workspaceRoot, "报告 final.txt");
    assert.equal(path.dirname(destination), workspaceRoot);
    assert.equal(path.basename(destination), "报告_final.txt");
    fs.writeFileSync(destination, "x");
    assert.equal(
      path.basename(pickExportDestination(workspaceRoot, "报告 final.txt")),
      "报告_final-1.txt",
    );

    const exported = performExportOpen(path.join(allowedRoot, "dir", "nested.txt"), unitConfig);
    assert.ok(exported.startsWith(path.join(workspaceRoot, EXPORT_DIR_NAME)));
    assert.equal(fs.readFileSync(exported, "utf8"), "nested");
    assert.throws(
      () => performExportOpen(path.join(allowedRoot, "report.txt"), {
        visibleRoots: [],
        workspaceRoot: null,
        homeRoot: null,
      }),
      (error) => error.statusCode === 503,
    );

    const runExportRequest = (method, body) => new Promise((resolve, reject) => {
      const { EventEmitter } = require("events");
      const request = new EventEmitter();
      request.method = method;
      let statusCode;
      let rawPayload = "";
      const response = {
        writeHead(code) { statusCode = code; },
        end(data) { rawPayload = data || ""; },
      };
      process.nextTick(() => {
        if (body !== undefined) request.emit("data", Buffer.from(body));
        request.emit("end");
      });
      handleExportOpenRequest(request, response, unitConfig)
        .then(() => resolve({
          statusCode,
          payload: rawPayload === "" ? null : JSON.parse(rawPayload),
        }))
        .catch(reject);
    });

    assert.equal((await runExportRequest("GET", undefined)).statusCode, 405);
    assert.equal((await runExportRequest("POST", "not json")).statusCode, 400);
    const okExport = await runExportRequest(
      "POST",
      JSON.stringify({ path: path.join(allowedRoot, "report.txt") }),
    );
    assert.equal(okExport.statusCode, 200);
    assert.equal(fs.readFileSync(okExport.payload.path, "utf8"), "payload");
    assert.equal(
      (await runExportRequest(
        "POST",
        JSON.stringify({ path: path.join(outsideRoot, "secret.txt") }),
      )).statusCode,
      403,
    );

    // __fnos/stat probe: directories answer true, files false, failures non-2xx.
    assert.equal(statProbeIsDirectory(path.join(allowedRoot, "dir"), unitConfig), true);
    assert.equal(statProbeIsDirectory(path.join(allowedRoot, "report.txt"), unitConfig), false);
    assert.throws(
      () => statProbeIsDirectory(path.join(allowedRoot, "missing"), unitConfig),
      (error) => error.statusCode === 404,
    );
    assert.throws(
      () => statProbeIsDirectory(outsideRoot, unitConfig),
      (error) => error.statusCode === 403,
    );
    assert.throws(
      () => statProbeIsDirectory("relative", unitConfig),
      (error) => error.statusCode === 400,
    );

    const runStatRequest = (method, body) => new Promise((resolve, reject) => {
      const { EventEmitter } = require("events");
      const request = new EventEmitter();
      request.method = method;
      let statusCode;
      let rawPayload = "";
      const response = {
        writeHead(code) { statusCode = code; },
        end(data) { rawPayload = data || ""; },
      };
      process.nextTick(() => {
        if (body !== undefined) request.emit("data", Buffer.from(body));
        request.emit("end");
      });
      handlePathStatRequest(request, response, unitConfig)
        .then(() => resolve({
          statusCode,
          payload: rawPayload === "" ? null : JSON.parse(rawPayload),
        }))
        .catch(reject);
    });

    assert.equal((await runStatRequest("GET", undefined)).statusCode, 405);
    assert.equal((await runStatRequest("POST", "not json")).statusCode, 400);
    const okDirStat = await runStatRequest(
      "POST",
      JSON.stringify({ path: path.join(allowedRoot, "dir") }),
    );
    assert.equal(okDirStat.statusCode, 200);
    assert.equal(okDirStat.payload.isDir, true);
    assert.equal(
      (await runStatRequest(
        "POST",
        JSON.stringify({ path: path.join(outsideRoot, "secret.txt") }),
      )).statusCode,
      403,
    );
  } finally {
    fs.rmSync(helperRoot, { recursive: true, force: true });
  }
}

async function testGatewayLocalRoutes() {
  const routeRoot = fs.mkdtempSync(path.join(os.tmpdir(), "gateway-fnos-routes-"));
  const packageHome = path.join(routeRoot, "app-home");
  const homeRoot = path.join(packageHome, ".dsh");
  const workspaceRoot = path.join(routeRoot, "workspace");
  fs.mkdirSync(homeRoot, { recursive: true });
  fs.mkdirSync(packageHome, { recursive: true });
  fs.mkdirSync(workspaceRoot, { recursive: true });
  fs.writeFileSync(path.join(homeRoot, "inside.txt"), "inside-payload");
  fs.writeFileSync(path.join(routeRoot, "outside.txt"), "outside-payload");
  const previousEnv = {
    TRIM_DATA_SHARE_PATHS: process.env.TRIM_DATA_SHARE_PATHS,
    TRIM_DATA_ACCESSIBLE_PATHS: process.env.TRIM_DATA_ACCESSIBLE_PATHS,
    TRIM_PKGVAR: process.env.TRIM_PKGVAR,
    TRIM_PKGHOME: process.env.TRIM_PKGHOME,
    DSH_WORKSPACE: process.env.DSH_WORKSPACE,
    DSH_HOME: process.env.DSH_HOME,
  };
  process.env.DSH_WORKSPACE = workspaceRoot;
  process.env.DSH_HOME = homeRoot;
  delete process.env.TRIM_DATA_SHARE_PATHS;
  delete process.env.TRIM_DATA_ACCESSIBLE_PATHS;
  delete process.env.TRIM_PKGVAR;
  process.env.TRIM_PKGHOME = packageHome;

  const launchToken = "d".repeat(43);
  const tokenPath = path.join(routeRoot, "web-auth.token");
  fs.writeFileSync(tokenPath, `${launchToken}\n`, { mode: 0o600 });
  let routeAuthCookieName;
  const sessionExportRequests = [];
  const sessionArchive = Buffer.from([0x50, 0x4b, 0x03, 0x04, ...Buffer.from("session-archive")]);
  const backend = http.createServer((request, response) => {
    if (new URL(request.url || "/", "http://backend.test").pathname === "/api/session.export") {
      sessionExportRequests.push({ url: request.url, cookie: request.headers.cookie });
      if (request.headers.cookie !== `${routeAuthCookieName}=route-session`) {
        response.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
        response.end("authentication required\n");
        return;
      }
      response.writeHead(200, {
        "content-type": "application/zip",
        "content-length": String(sessionArchive.length),
      });
      response.end(sessionArchive);
      return;
    }
    if (new URL(request.url || "/", "http://backend.test").pathname === "/"
      && new URL(request.url || "/", "http://backend.test").searchParams.has("token")) {
      response.writeHead(303, {
        location: "/",
        "set-cookie": `${routeAuthCookieName}=route-session; Path=/; HttpOnly`,
      });
      response.end();
      return;
    }
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end("<!doctype html><html><head></head><body>backend</body></html>");
  });
  const socketPath = process.platform === "win32"
    ? `\\\\.\\pipe\\dsh-gateway-fnos-test-${process.pid}-${Date.now()}`
    : path.join(routeRoot, "gw.sock");
  let gateway;
  try {
    await listen(backend, 0, "127.0.0.1");
    const address = backend.address();
    routeAuthCookieName = backendAuthCookieName({ host: "127.0.0.1", port: address.port });
    gateway = startGatewayProxy({
      socketPath,
      gatewayPrefix: prefix,
      target: { host: "127.0.0.1", port: address.port },
      authTokenPath: tokenPath,
    });

    const headers = { "x-trim-isadmin": "true" };
    const enhancer = await requestGateway(socketPath, headers, FNOS_OPEN_ENHANCER_PATH);
    assert.equal(enhancer.status, 200);
    assert.match(enhancer.headers["content-type"], /application\/javascript/);
    assert.ok(!enhancer.body.includes("data-dsh-fnos-open"));
    assert.ok(!enhancer.body.includes("readCardOpenButton"));
    assert.ok(enhancer.body.includes("/open-in-app/apps"));
    assert.ok(enhancer.body.includes("/open-in-app/open"));
    assert.ok(enhancer.body.includes("withWebCarrierUserAgent"));
    assert.ok(enhancer.body.includes("openFileManager"));

    const sdk = await requestGateway(socketPath, headers, TRIM_WEB_APP_PATH);
    assert.equal(sdk.status, 200);
    assert.ok(sdk.body.startsWith("var TrimAppSDK"));

    // Root GET without a browser cookie triggers the server-side exchange
    // (303 + set-cookie); replay with the cookie to load the shell.
    const exchange = await requestGateway(socketPath, headers, "/");
    assert.equal(exchange.status, 303);
    const routeCookie = String(exchange.headers["set-cookie"][0]).split(";", 1)[0];
    const shell = await requestGateway(socketPath, { ...headers, cookie: routeCookie }, "/");
    assert.equal(shell.status, 200);
    assert.match(shell.body, /window\.__DSH_FNOS__/);
    assert.ok(shell.body.includes(`${prefix}${FNOS_OPEN_ENHANCER_PATH}`));
    assert.ok(shell.body.includes(`${prefix}${TRIM_WEB_APP_PATH}`));

    const exportRequest = (requestPath, method, body) => new Promise((resolve, reject) => {
      const request = http.request(
        {
          socketPath,
          method,
          path: `${prefix}${requestPath}`,
          headers: { ...headers, "content-type": "application/json" },
        },
        (response) => {
          const chunks = [];
          response.on("data", (chunk) => chunks.push(chunk));
          response.on("end", () => resolve({
            status: response.statusCode,
            body: Buffer.concat(chunks).toString("utf8"),
          }));
        },
      );
      request.on("error", reject);
      request.end(body);
    });

    const exported = await exportRequest(EXPORT_OPEN_PATH, "POST", JSON.stringify({
      path: path.join(homeRoot, "inside.txt"),
    }));
    assert.equal(exported.status, 200);
    const exportedPath = JSON.parse(exported.body).path;
    assert.ok(exportedPath.startsWith(path.join(workspaceRoot, EXPORT_DIR_NAME)));
    assert.equal(fs.readFileSync(exportedPath, "utf8"), "inside-payload");
    const exportedAgain = await exportRequest(EXPORT_OPEN_PATH, "POST", JSON.stringify({
      path: path.join(homeRoot, "inside.txt"),
    }));
    assert.equal(path.basename(JSON.parse(exportedAgain.body).path), "inside-1.txt");

    assert.equal(
      (await exportRequest(EXPORT_OPEN_PATH, "POST", JSON.stringify({
        path: path.join(homeRoot, "..", "..", "outside.txt"),
      }))).status,
      403,
    );
    assert.equal(
      (await exportRequest(EXPORT_OPEN_PATH, "POST", JSON.stringify({
        path: path.join(homeRoot, "missing.txt"),
      }))).status,
      404,
    );
    assert.equal(
      (await exportRequest(EXPORT_OPEN_PATH, "POST", JSON.stringify({ path: homeRoot }))).status,
      400,
    );
    assert.equal((await exportRequest(EXPORT_OPEN_PATH, "GET", undefined)).status, 405);

    const sessionExport = await exportRequest(
      SESSION_EXPORT_PATH,
      "POST",
      JSON.stringify({ sessionId: "session-123", includeDescendants: true }),
    );
    assert.equal(sessionExport.status, 200);
    const sessionExportPath = JSON.parse(sessionExport.body).path;
    assert.deepEqual(fs.readFileSync(sessionExportPath), sessionArchive);
    // The export route authenticates: the gateway must inject its own
    // session cookie instead of forwarding the browser's (absent) one.
    assert.deepEqual(sessionExportRequests, [{
      url: "/api/session.export?sessionId=session-123&includeDescendants=true",
      cookie: `${routeAuthCookieName}=route-session`,
    }]);
    assert.match(path.basename(sessionExportPath), /^dsh-session-session-123\.zip$/);
    assert.equal(
      (await exportRequest(
        SESSION_EXPORT_PATH,
        "POST",
        JSON.stringify({ sessionId: "../outside" }),
      )).status,
      400,
    );
    assert.equal((await exportRequest(SESSION_EXPORT_PATH, "GET", undefined)).status, 405);
  } finally {
    await close(gateway);
    await close(backend);
    if (process.platform !== "win32") fs.rmSync(socketPath, { force: true });
    fs.rmSync(routeRoot, { recursive: true, force: true });
    if (previousEnv.TRIM_DATA_SHARE_PATHS === undefined) delete process.env.TRIM_DATA_SHARE_PATHS;
    else process.env.TRIM_DATA_SHARE_PATHS = previousEnv.TRIM_DATA_SHARE_PATHS;
    if (previousEnv.TRIM_DATA_ACCESSIBLE_PATHS === undefined) {
      delete process.env.TRIM_DATA_ACCESSIBLE_PATHS;
    } else {
      process.env.TRIM_DATA_ACCESSIBLE_PATHS = previousEnv.TRIM_DATA_ACCESSIBLE_PATHS;
    }
    if (previousEnv.TRIM_PKGVAR === undefined) delete process.env.TRIM_PKGVAR;
    else process.env.TRIM_PKGVAR = previousEnv.TRIM_PKGVAR;
    if (previousEnv.TRIM_PKGHOME === undefined) delete process.env.TRIM_PKGHOME;
    else process.env.TRIM_PKGHOME = previousEnv.TRIM_PKGHOME;
    if (previousEnv.DSH_WORKSPACE === undefined) delete process.env.DSH_WORKSPACE;
    else process.env.DSH_WORKSPACE = previousEnv.DSH_WORKSPACE;
    if (previousEnv.DSH_HOME === undefined) delete process.env.DSH_HOME;
    else process.env.DSH_HOME = previousEnv.DSH_HOME;
  }
}

Promise.all([
  testGatewayUpgradeForwardsClientBytesOnce(),
  testGatewayAuthorization(),
  testGatewayBrowserAuthentication(),
  testGatewayAuthResilience(),
  testFnosExportHelpers(),
  testGatewayLocalRoutes(),
])
  .then(() => process.stdout.write("gateway-proxy tests passed\n"))
  .catch((error) => {
    process.stderr.write(`${error.stack || error.message}\n`);
    process.exitCode = 1;
  });
