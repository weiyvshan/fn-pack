#!/usr/bin/env node
"use strict";

const fs = require("fs");
const http = require("http");
const net = require("net");
const path = require("path");
const { createHash } = require("crypto");
const { relayWebSocket, validateTimeout } = require("./gateway-websocket.js");
const { rewriteChangesSummaryClient } = require("./summary-client-compat.js");
const {
  knownRoots,
  packageDirectory,
  profileDependencies,
  readRegistry,
  rootsForProfile,
} = require("./gateway-compat.js");

const MAX_REWRITE_BYTES = 20 * 1024 * 1024;
const POLYFILL_PATH = "/__fnos/polyfill.js";
const FNOS_OPEN_ENHANCER_PATH = "/__fnos/fnos-open.js";
const TRIM_WEB_APP_PATH = "/__fnos/trim-web-app.js";
const EXPORT_OPEN_PATH = "/__fnos/export-open";
const PATH_STAT_PATH = "/__fnos/stat";
const SESSION_EXPORT_PATH = "/__fnos/export-session";
const SESSION_EXPORT_UPSTREAM_PATH = "/api/session.export";
const FNOS_OPEN_ENHANCER_FILE = path.join(__dirname, "web", "fnos-open-enhancer.js");
const TRIM_WEB_APP_FILE = path.join(__dirname, "web", "trim-web-app-0.4.2.iife.js");
const EXPORT_DIR_NAME = "dsh-exports";
const EXPORT_OPEN_BODY_LIMIT = 64 * 1024;
const SESSION_EXPORT_BODY_LIMIT = 16 * 1024;
const SESSION_EXPORT_MAX_BYTES = 256 * 1024 * 1024;
const SESSION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/;
const AUTH_COOKIE_PREFIX = "dsh-auth-";
const LAUNCH_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
// One-shot retry budget shared by HTTP forwards and WebSocket upgrades: a
// rejected cached gateway cookie refreshes it once per request, then surfaces
// the upstream rejection instead of looping.
const AUTH_EXCHANGE_TIMEOUT_MS = 10 * 1000;
const MARKER = "dsh-fnos-gateway-adapter";
const SETTINGS_CLIENT_MARKER = "new SettingsDescribeMirror(ctx, persistence)";
const SETTINGS_HOST_PERSISTENCE_ASSIGNMENTS = [
  'ctx.remote.$host.isLoopback ? "host" : "memory"',
  'connection.isLoopback ? "host" : "memory"',
];
const SETTINGS_CLIENT_ROUTE =
  "@deepseek-ai/dsh-client-ui-settings/client.js";
const PLUGIN_MANAGER_MARKER =
  "plugin-manager: plugin management is only available from a local browser";
const PLUGIN_MANAGER_LOOPBACK_ASSIGNMENTS = [
  "isLoopback: connection.isLoopback",
  "isLoopback:connection.isLoopback",
];
const REMOTE_WEB_UI_CONTAINER_MARKERS = [
  'id: "@linxin666/dsh-remote-web-ui"',
  'id: "@linxin666/dsh-web-all"',
];
const REMOTE_WEB_UI_MARKERS = [
  "remote-web-ui: pair flow + heartbeats",
  "remote-web-ui: remote desktop channel",
  "/api/pair/heartbeat",
];
const REMOTE_WEB_UI_LOOPBACK_ASSIGNMENT =
  'const loopback = ctx.get("connection")?.isLoopback ?? true;';
const REMOTE_WEB_UI_CHANNEL_FENCES = [
  "if (isLoopbackHostname(window.location.hostname)) return false;",
  "if (isLoopbackHostname(hostname)) return false;",
];
const BETTER_SIDEBAR_WS_MARKER = "dsh-fnos-better-sidebar-ws";
const BETTER_SIDEBAR_CONTAINER_MARKERS = [
  'id: "dsh-better-sidebar"',
  'id: "dsh-external/dsh-better-sidebar"',
];
const BETTER_SIDEBAR_WS_CHANNELS = [
  {
    path: "/sidebar/ws/agent-terminals",
    failure: "agent-terminals connection failed; stopping reconnect loop",
  },
  {
    path: "/sidebar/ws/agent-opens",
    failure: "agent-opens connection failed; stopping reconnect loop",
  },
];
const BETTER_SIDEBAR_CLIENT_ROUTES = [
  "dsh-better-sidebar/client.js",
  "dsh-better-sidebar/client-registry.js",
];
const MOBILE_UI_CLIENT_ROUTE = "dsh-mobile-ui/client.js";
const MOBILE_UI_BROKEN_REGISTRATIONS = [
  "id: '@deepseek-ai/dsh-mobile-ui'",
  'id: "@deepseek-ai/dsh-mobile-ui"',
];
const MOBILE_UI_CORRECT_REGISTRATIONS = [
  "id: 'dsh-mobile-ui'",
  'id: "dsh-mobile-ui"',
];
const MOBILE_UI_MARKERS = [
  "mobile-viewport/change",
  "mobile-bottom-nav",
  "data-dsh-mobile",
];
const SUMMARY_CLIENT_ROUTE = "@deepseek-ai/dsh-client-ui-deliverables/client.js";
const ADAPTED_PLUGIN_CLIENT_ROUTES = [
  SUMMARY_CLIENT_ROUTE,
  SETTINGS_CLIENT_ROUTE,
  "@linxin666/dsh-client-ui-plugin-manager/client.js",
  "@linxin666/dsh-remote-web-ui/client.js",
  "@linxin666/dsh-web-all/client.js",
  ...BETTER_SIDEBAR_CLIENT_ROUTES,
  MOBILE_UI_CLIENT_ROUTE,
];
const ADAPTED_PLUGIN_CLIENT_PATHS = new Set([
  ...ADAPTED_PLUGIN_CLIENT_ROUTES.map((route) => `/plugins/${route}`),
]);
const BUILTIN_REWRITE_PREFIXES = [
  "/assets/",
  "/plugins/",
  "/api/",
  "/open-in-app/",
  "/favicon",
  "/manifest",
  "/icons/",
];
const STRIP_REQUEST_HEADERS = new Set([
  "accept-encoding",
  "origin",
  "referer",
  "sec-fetch-site",
  "sec-fetch-mode",
  "sec-fetch-dest",
  "sec-fetch-user",
  "sec-ch-ua",
  "sec-ch-ua-mobile",
  "sec-ch-ua-platform",
  "sec-ch-ua-platform-version",
  "sec-ch-ua-full-version-list",
  "sec-ch-prefers-color-scheme",
  "sec-ch-viewport-width",
  "x-requested-with",
  "x-trim-userid",
  "x-trim-isadmin",
  "x-trim-username",
]);

const RANDOM_UUID_POLYFILL = `/* ${MARKER} */
(function () {
  var g = typeof globalThis !== "undefined" ? globalThis : window;
  var c = g.crypto;
  if (!c) {
    try { c = g.crypto = {}; } catch (_) { c = {}; }
  }
  if (typeof c.randomUUID !== "function" && typeof c.getRandomValues === "function") {
    c.randomUUID = function () {
      var b = c.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 15) | 64;
      b[8] = (b[8] & 63) | 128;
      var h = "";
      for (var i = 0; i < b.length; i += 1) {
        if (i === 4 || i === 6 || i === 8 || i === 10) h += "-";
        h += (b[i] < 16 ? "0" : "") + b[i].toString(16);
      }
      return h;
    };
  }
})();\n`;

function normalizePrefix(value) {
  const prefix = String(value || "/app/deepseek-harness").replace(/\/+$/, "");
  if (!/^\/app\/[A-Za-z0-9_-]+(?:\/[A-Za-z0-9._~-]+)*$/.test(prefix)) {
    throw new Error(`invalid gateway prefix: ${prefix}`);
  }
  return prefix;
}

function parseTarget(value) {
  const match = /^([A-Za-z0-9.-]+):([0-9]{1,5})$/.exec(String(value));
  if (!match) throw new Error(`invalid target: ${value}`);
  const port = Number(match[2]);
  if (port < 1 || port > 65535) throw new Error(`invalid target port: ${port}`);
  return { host: match[1], port };
}

function parsePid(value) {
  const pid = Number(value);
  if (!Number.isInteger(pid) || pid < 1) throw new Error(`invalid backend pid: ${value}`);
  return pid;
}

function base64Url(value) {
  return value
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function backendAuthCookieName(target) {
  const backend = typeof target === "string" ? parseTarget(target) : target;
  const authority = new URL(`http://${backend.host}:${backend.port}`).host;
  return AUTH_COOKIE_PREFIX + base64Url(createHash("sha256").update(authority).digest());
}

function hasCookie(rawCookie, name) {
  if (typeof rawCookie !== "string") return false;
  return rawCookie.split(";").some((segment) => {
    const at = segment.indexOf("=");
    return at !== -1 && segment.slice(0, at).trim() === name;
  });
}

function readLaunchToken(filePath) {
  if (!filePath) throw new Error("browser authentication token file is required");
  const metadata = fs.lstatSync(filePath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error("browser authentication token path must be a regular file");
  }
  if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
    throw new Error("browser authentication token file permissions must be 0600 or stricter");
  }
  if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
    throw new Error("browser authentication token file must be owned by the gateway user");
  }
  const tokenText = fs.readFileSync(filePath, "utf8");
  const token = tokenText.endsWith("\n") ? tokenText.slice(0, -1) : tokenText;
  if (!LAUNCH_TOKEN_PATTERN.test(token)) {
    throw new Error("browser authentication token file contains an invalid token");
  }
  return token;
}

function rootPathWithoutClientToken(requestPath) {
  const parsed = new URL(String(requestPath || "/"), "http://gateway.invalid");
  if (parsed.pathname !== "/") return String(requestPath || "/");
  parsed.searchParams.delete("token");
  return `${parsed.pathname}${parsed.search}`;
}

function tokenExchangePath(requestPath, launchToken) {
  const parsed = new URL(rootPathWithoutClientToken(requestPath), "http://gateway.invalid");
  if (parsed.pathname !== "/") throw new Error("browser token exchange is restricted to the root path");
  parsed.searchParams.set("token", launchToken);
  return `${parsed.pathname}${parsed.search}`;
}

function isProcessRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

function isAdminRequest(headers) {
  return String(headers["x-trim-isadmin"] || "").toLowerCase() === "true";
}

function isGatewayPath(requestUrl, gatewayPrefix) {
  const pathname = String(requestUrl || "/").split("?", 1)[0];
  return pathname === gatewayPrefix || pathname.startsWith(`${gatewayPrefix}/`);
}

function stripPrefix(requestUrl, gatewayPrefix) {
  const question = requestUrl.indexOf("?");
  const pathname = question === -1 ? requestUrl : requestUrl.slice(0, question);
  const query = question === -1 ? "" : requestUrl.slice(question);
  let stripped = pathname;
  if (pathname === gatewayPrefix) stripped = "/";
  else if (pathname.startsWith(`${gatewayPrefix}/`)) stripped = pathname.slice(gatewayPrefix.length);
  return `${stripped || "/"}${query}`;
}

function buildHeaders(
  original,
  target,
  { upgrade = false, gatewayAuthenticated = false, disableRevalidation = false } = {},
) {
  const headers = { ...original };
  for (const name of STRIP_REQUEST_HEADERS) delete headers[name];
  if (disableRevalidation) {
    delete headers["if-none-match"];
    delete headers["if-modified-since"];
  }
  headers.host = `${target.host}:${target.port}`;
  // The fnOS gateway has authenticated this request before the application
  // proxy creates the loopback-only upstream request. Do not forward browser
  // provenance headers supplied by the client; attest the internal hop here.
  if (gatewayAuthenticated) headers["sec-fetch-site"] = "same-origin";
  if (!upgrade) headers.connection = "close";
  return headers;
}

function mergeBackendAuthCookie(rawCookie, authCookieName, authCookie) {
  const cookies = typeof rawCookie === "string"
    ? rawCookie.split(";").map((value) => value.trim()).filter(Boolean)
    : [];
  const filtered = cookies.filter((value) => {
    const separator = value.indexOf("=");
    const name = separator === -1 ? value : value.slice(0, separator);
    return name !== authCookieName && !name.startsWith(AUTH_COOKIE_PREFIX);
  });
  filtered.push(authCookie);
  return filtered.join("; ");
}

function requestBackendAuthCookie(backend, launchToken, authCookieName, timeoutMs = AUTH_EXCHANGE_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      exchange.destroy();
      reject(error);
    };
    const exchange = http.request(
      {
        host: backend.host,
        port: backend.port,
        method: "GET",
        path: tokenExchangePath("/", launchToken),
        headers: buildHeaders({}, backend, { gatewayAuthenticated: true }),
      },
      (response) => {
        if (response.statusCode !== 200 && response.statusCode !== 303) {
          const error = new Error(`backend authentication exchange failed (HTTP ${response.statusCode || 0})`);
          response.resume();
          response.once("end", () => fail(error));
          return;
        }
        const rawCookies = response.headers["set-cookie"];
        const cookies = Array.isArray(rawCookies)
          ? rawCookies
          : typeof rawCookies === "string" ? [rawCookies] : [];
        const prefix = `${authCookieName}=`;
        const authCookie = cookies
          .map((value) => String(value).split(";", 1)[0])
          .find((value) => value.startsWith(prefix));
        response.resume();
        response.once("error", fail);
        response.once("end", () => {
          if (authCookie === undefined) {
            fail(new Error("backend authentication exchange did not return the expected cookie"));
            return;
          }
          if (settled) return;
          settled = true;
          resolve(authCookie);
        });
      },
    );
    exchange.once("error", fail);
    if (timeoutMs > 0) exchange.setTimeout(timeoutMs, () => fail(new Error("backend authentication exchange timed out")));
    exchange.end();
  });
}

function isAdaptedPluginClientPath(requestPath) {
  const value = String(requestPath || "");
  const pathname = value.split("?", 1)[0];
  return ADAPTED_PLUGIN_CLIENT_PATHS.has(pathname)
    || (pathname === "/plugins/"
      && ADAPTED_PLUGIN_CLIENT_ROUTES.some((route) => value.includes(route)));
}

function rewriteLocation(location, gatewayPrefix, dynamicPrefixes = []) {
  if (typeof location !== "string") return location;
  if (location === "/") return `${gatewayPrefix}/`;
  if (location.startsWith("/") && !location.startsWith(`${gatewayPrefix}/`)) {
    const pathname = location.split("?", 1)[0];
    if (rewritePrefixes(dynamicPrefixes).some(root => pathname === root.slice(0, -1) || pathname.startsWith(root))) {
      return `${gatewayPrefix}${location}`;
    }
  }
  return location;
}

function rewriteSetCookie(value, gatewayPrefix) {
  if (Array.isArray(value)) return value.map((item) => rewriteSetCookie(item, gatewayPrefix));
  if (typeof value !== "string") return value;
  return value.replace(/;\s*Path=\/(?![^;])/i, `; Path=${gatewayPrefix}/`);
}

function rewritePrefixes(dynamicPrefixes) {
  return [...new Set([...BUILTIN_REWRITE_PREFIXES, ...(dynamicPrefixes || [])])];
}

function rewritePluginManagerLoopback(body) {
  if (!body.includes(PLUGIN_MANAGER_MARKER)) return body;
  let output = body;
  for (const assignment of PLUGIN_MANAGER_LOOPBACK_ASSIGNMENTS) {
    output = output.split(assignment).join("isLoopback: true");
  }
  return output;
}

function rewriteSettingsHostPersistence(body) {
  if (!body.includes(SETTINGS_CLIENT_MARKER)) return body;
  const matches = SETTINGS_HOST_PERSISTENCE_ASSIGNMENTS.flatMap((assignment) =>
    Array(body.split(assignment).length - 1).fill(assignment)
  );
  if (matches.length !== 1) return body;
  return body.replace(matches[0], '"host"');
}

function rewriteRemoteWebUiLoopback(body) {
  const modulePrefix = "window.__ModuleLoader__.load({";
  const modules = body.split(modulePrefix);
  if (modules.length === 1) return body;

  for (let index = 1; index < modules.length; index += 1) {
    const moduleBody = modules[index];
    if (!REMOTE_WEB_UI_CONTAINER_MARKERS.some((marker) => moduleBody.includes(marker))) continue;
    if (!REMOTE_WEB_UI_MARKERS.every((marker) => moduleBody.includes(marker))) continue;
    const assignments = moduleBody.split(REMOTE_WEB_UI_LOOPBACK_ASSIGNMENT).length - 1;
    const channelFences = REMOTE_WEB_UI_CHANNEL_FENCES.flatMap((fence) =>
      Array(moduleBody.split(fence).length - 1).fill(fence)
    );
    if (assignments !== 1 || channelFences.length !== 1) continue;
    modules[index] = moduleBody
      .replace(REMOTE_WEB_UI_LOOPBACK_ASSIGNMENT, "const loopback = true;")
      .replace(channelFences[0], "if (true) return false;");
  }
  return modules.join(modulePrefix);
}

function rewriteBetterSidebarWebSocketResilience(body) {
  const modulePrefix = "window.__ModuleLoader__.load({";
  const modules = body.split(modulePrefix);
  if (modules.length === 1) return body;

  const rewrites = [
    {
      search: "\t\t\t\tlet retry;\n\t\t\t\tlet closed = false;",
      replacement: "\t\t\t\tlet retry;\n\t\t\t\tlet keepAlive;\n\t\t\t\tlet closed = false;",
    },
    {
      search: "\t\t\t\t\tsocket = new WebSocket(url.toString());\n\t\t\t\t\tsocket.onmessage = (event) => {",
      replacement: [
        "\t\t\t\t\tsocket = new WebSocket(url.toString());",
        "\t\t\t\t\tsocket.onopen = () => {",
        "\t\t\t\t\t\tfailures = 0;",
        "\t\t\t\t\t\twindow.clearInterval(keepAlive);",
        "\t\t\t\t\t\tkeepAlive = window.setInterval(() => {",
        "\t\t\t\t\t\t\tif (socket?.readyState === 1) socket.send(\"ping\");",
        "\t\t\t\t\t\t}, 25000);",
        "\t\t\t\t\t};",
        "\t\t\t\t\tsocket.onmessage = (event) => {",
      ].join("\n"),
    },
    {
      search: "\t\t\t\t\tsocket.onclose = () => {\n\t\t\t\t\t\tif (closed) return;",
      replacement: [
        "\t\t\t\t\tsocket.onclose = () => {",
        "\t\t\t\t\t\twindow.clearInterval(keepAlive);",
        "\t\t\t\t\t\tkeepAlive = undefined;",
        "\t\t\t\t\t\tif (closed) return;",
      ].join("\n"),
    },
    {
      search: "\t\t\t\t\twindow.clearTimeout(retry);\n\t\t\t\t\tsocket?.close();",
      replacement: [
        "\t\t\t\t\twindow.clearTimeout(retry);",
        "\t\t\t\t\twindow.clearInterval(keepAlive);",
        "\t\t\t\t\tsocket?.close();",
      ].join("\n"),
    },
  ];

  for (let index = 1; index < modules.length; index += 1) {
    const moduleBody = modules[index];
    if (!BETTER_SIDEBAR_CONTAINER_MARKERS.some((marker) => moduleBody.includes(marker))) continue;
    if (moduleBody.includes(BETTER_SIDEBAR_WS_MARKER)) continue;
    if (!moduleBody.includes("const FAILURE_LIMIT = 3;")) continue;
    if (!BETTER_SIDEBAR_WS_CHANNELS.every(({ path, failure }) =>
      moduleBody.split(path).length === 2 && moduleBody.split(failure).length === 2
    )) continue;
    if (!rewrites.every(({ search }) => moduleBody.split(search).length === 3)) continue;

    let rewritten = moduleBody;
    for (const { search, replacement } of rewrites) {
      rewritten = rewritten.split(search).join(replacement);
    }
    modules[index] = `\n\t/* ${BETTER_SIDEBAR_WS_MARKER} */${rewritten}`;
  }
  return modules.join(modulePrefix);
}

function rewriteMobileUiRegistration(body) {
  const modulePrefix = "window.__ModuleLoader__.load({";
  const modules = body.split(modulePrefix);
  if (modules.length === 1) return body;

  for (let index = 1; index < modules.length; index += 1) {
    const moduleBody = modules[index];
    if (!MOBILE_UI_MARKERS.every((marker) => moduleBody.includes(marker))) continue;
    const broken = MOBILE_UI_BROKEN_REGISTRATIONS.flatMap((registration) =>
      Array(moduleBody.split(registration).length - 1).fill(registration)
    );
    const corrected = MOBILE_UI_CORRECT_REGISTRATIONS.reduce(
      (count, registration) => count + moduleBody.split(registration).length - 1,
      0,
    );
    if (broken.length !== 1 || corrected !== 0) continue;
    modules[index] = moduleBody.replace(
      broken[0],
      broken[0].replace("@deepseek-ai/dsh-mobile-ui", "dsh-mobile-ui"),
    );
  }
  return modules.join(modulePrefix);
}

function installedPackageName(packagePath) {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(packagePath, "package.json"), "utf8"));
    return typeof manifest.name === "string" ? manifest.name : null;
  } catch (_) {
    return null;
  }
}

function readDynamicPrefixes(
  compatPath,
  profile = "web",
  profilesRoot = process.env.DSH_GATEWAY_PROFILES_ROOT,
) {
  const roots = new Set(rootsForProfile(readRegistry(compatPath), profile));
  if (!profilesRoot) return [...roots].sort();
  const profileDirectory = path.join(profilesRoot, profile);
  for (const packageName of Object.keys(profileDependencies(profileDirectory))) {
    const installedDirectory = packageDirectory(profileDirectory, packageName);
    if (installedDirectory === null || installedPackageName(installedDirectory) !== packageName) continue;
    for (const root of knownRoots(packageName)) roots.add(root);
  }
  return [...roots].sort();
}

function safeRealPath(value) {
  if (typeof value !== "string" || value === "") return null;
  try {
    return fs.realpathSync(value);
  } catch (_) {
    return null;
  }
}

// The proxy child inherits fnOS-provisioned shares, package data, the package
// home, DSH_HOME, and DSH_WORKSPACE from cmd/main. Visible roots decide whether a
// presented file can be opened by the browser-side fnOS SDK directly or must
// be exported first; they are also containment roots for the export endpoint.
function readFnosEnvConfig(env = process.env) {
  const visibleRoots = [];
  const packageHome = safeRealPath(env.TRIM_PKGHOME);
  for (const value of [
    env.TRIM_DATA_SHARE_PATHS,
    env.TRIM_DATA_ACCESSIBLE_PATHS,
    env.TRIM_PKGVAR,
    env.TRIM_PKGHOME,
  ]) {
    for (const candidate of String(value || "").split(path.delimiter)) {
      const resolved = safeRealPath(candidate.trim());
      if (resolved && !visibleRoots.includes(resolved)) visibleRoots.push(resolved);
    }
  }
  const workspaceRoot = safeRealPath(String(env.DSH_WORKSPACE || ""))
    || visibleRoots[0]
    || null;
  const dshHome = packageHome
    ? safeRealPath(path.join(packageHome, ".dsh"))
    : safeRealPath(env.DSH_HOME);
  return {
    visibleRoots,
    workspaceRoot,
    homeRoot: dshHome,
  };
}

function fnosBrowserConfig(gatewayPrefix, envConfig = readFnosEnvConfig()) {
  return {
    prefix: gatewayPrefix,
    workspaceRoot: envConfig.workspaceRoot,
    visibleRoots: envConfig.visibleRoots,
    sdkPath: `${gatewayPrefix}${TRIM_WEB_APP_PATH}`,
    exportPath: `${gatewayPrefix}${EXPORT_OPEN_PATH}`,
    statPath: `${gatewayPrefix}${PATH_STAT_PATH}`,
    sessionExportPath: `${gatewayPrefix}${SESSION_EXPORT_PATH}`,
  };
}

function isPathWithinRoot(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== ""
    && !relative.startsWith("..")
    && !path.isAbsolute(relative);
}

function resolveExportSource(requestedPath, envConfig) {
  const reject = (statusCode, message) => {
    const error = new Error(message);
    error.statusCode = statusCode;
    throw error;
  };
  if (typeof requestedPath !== "string"
    || requestedPath === ""
    || requestedPath.length > 4096
    || !path.isAbsolute(requestedPath)) {
    reject(400, "path must be an absolute path");
  }
  let resolved;
  try {
    resolved = fs.realpathSync(requestedPath);
  } catch (_) {
    reject(404, "path does not exist");
  }
  let stats;
  try {
    stats = fs.statSync(resolved);
  } catch (_) {
    reject(404, "path is not readable");
  }
  if (!stats.isFile()) reject(400, "path is not a regular file");
  const roots = [...envConfig.visibleRoots, envConfig.homeRoot].filter(Boolean);
  if (!roots.some((root) => isPathWithinRoot(root, resolved))) {
    reject(403, "path is outside the export-allowed roots");
  }
  return resolved;
}

function sanitizeExportBasename(value) {
  const cleaned = String(value || "")
    .split(/[\\/]/)
    .pop()
    .replace(/[^.\p{L}\p{N}_-]/gu, "_")
    .replace(/^\.+/, "")
    .trim();
  if (cleaned === "" || cleaned === "." || cleaned === "..") return "file";
  return cleaned.slice(0, 128);
}

function pickExportDestination(exportRoot, sourceBasename) {
  const basename = sanitizeExportBasename(sourceBasename);
  fs.mkdirSync(exportRoot, { recursive: true });
  const dot = basename.lastIndexOf(".");
  const stem = dot > 0 ? basename.slice(0, dot) : basename;
  const extension = dot > 0 ? basename.slice(dot) : "";
  for (let counter = 0; ; counter += 1) {
    const candidate = path.join(
      exportRoot,
      counter === 0 ? basename : `${stem}-${counter}${extension}`,
    );
    if (!fs.existsSync(candidate)) return candidate;
    if (counter >= 999) {
      const error = new Error("export destination counter exhausted");
      error.statusCode = 500;
      throw error;
    }
  }
}

function performExportOpen(requestedPath, envConfig) {
  if (!envConfig || !envConfig.workspaceRoot) {
    const error = new Error("workspace root is unavailable");
    error.statusCode = 503;
    throw error;
  }
  const source = resolveExportSource(requestedPath, envConfig);
  const destination = pickExportDestination(
    path.join(envConfig.workspaceRoot, EXPORT_DIR_NAME),
    path.basename(source),
  );
  fs.copyFileSync(source, destination);
  return destination;
}

function readJsonBody(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    let overflow = false;
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > limit) {
        overflow = true;
        request.resume();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve({ overflow, body: Buffer.concat(chunks, Math.min(bytes, limit)) }));
    request.on("error", reject);
  });
}

// Read-only directory probe for the browser reveal adapter: same reachability
// boundary as export-open (visible roots + home root), but directories are
// valid answers. Every failure maps to a non-2xx so the client falls back to
// opening the parent directory instead of trusting a guess.
function statProbeIsDirectory(requestedPath, envConfig) {
  const reject = (statusCode, message) => {
    const error = new Error(message);
    error.statusCode = statusCode;
    throw error;
  };
  if (!envConfig || !envConfig.workspaceRoot) {
    reject(503, "workspace root is unavailable");
  }
  if (typeof requestedPath !== "string"
    || requestedPath === ""
    || requestedPath.length > 4096
    || !path.isAbsolute(requestedPath)) {
    reject(400, "path must be an absolute path");
  }
  let resolved;
  try {
    resolved = fs.realpathSync(requestedPath);
  } catch (_) {
    reject(404, "path does not exist");
  }
  let stats;
  try {
    stats = fs.statSync(resolved);
  } catch (_) {
    reject(404, "path is not readable");
  }
  const roots = [...envConfig.visibleRoots, envConfig.homeRoot].filter(Boolean);
  if (!roots.some((root) => isPathWithinRoot(root, resolved))) {
    reject(403, "path is outside the probe-allowed roots");
  }
  return stats.isDirectory();
}

async function handlePathStatRequest(request, response, envConfig) {
  const respond = (statusCode, payload) => {
    response.writeHead(statusCode, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(`${JSON.stringify(payload)}\n`);
  };
  if (request.method !== "POST") {
    respond(405, { error: "method not allowed" });
    return;
  }
  const { overflow, body } = await readJsonBody(request, EXPORT_OPEN_BODY_LIMIT);
  if (overflow) {
    respond(413, { error: "request body too large" });
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(body.toString("utf8"));
  } catch (_) {
    respond(400, { error: "invalid JSON body" });
    return;
  }
  try {
    respond(200, { isDir: statProbeIsDirectory(parsed && parsed.path, envConfig) });
  } catch (error) {
    respond(error && error.statusCode ? error.statusCode : 500, {
      error: error && error.message ? error.message : "stat failed",
    });
  }
}

async function handleExportOpenRequest(request, response, envConfig) {
  const respond = (statusCode, payload) => {
    response.writeHead(statusCode, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(`${JSON.stringify(payload)}\n`);
  };
  if (request.method !== "POST") {
    respond(405, { error: "method not allowed" });
    return;
  }
  const { overflow, body } = await readJsonBody(request, EXPORT_OPEN_BODY_LIMIT);
  if (overflow) {
    respond(413, { error: "request body too large" });
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(body.toString("utf8"));
  } catch (_) {
    respond(400, { error: "invalid JSON body" });
    return;
  }
  try {
    respond(200, { path: performExportOpen(parsed && parsed.path, envConfig) });
  } catch (error) {
    respond(error && error.statusCode ? error.statusCode : 500, {
      error: error && error.message ? error.message : "export failed",
    });
  }
}

function reserveExportDestination(exportRoot, basename) {
  fs.mkdirSync(exportRoot, { recursive: true });
  const safeBasename = sanitizeExportBasename(basename);
  const dot = safeBasename.lastIndexOf(".");
  const stem = dot > 0 ? safeBasename.slice(0, dot) : safeBasename;
  const extension = dot > 0 ? safeBasename.slice(dot) : "";
  for (let counter = 0; counter <= 999; counter += 1) {
    const candidate = path.join(
      exportRoot,
      counter === 0 ? safeBasename : `${stem}-${counter}${extension}`,
    );
    try {
      const descriptor = fs.openSync(candidate, "wx");
      fs.closeSync(descriptor);
      return candidate;
    } catch (error) {
      if (error && error.code === "EEXIST") continue;
      throw error;
    }
  }
  const error = new Error("export destination counter exhausted");
  error.statusCode = 500;
  throw error;
}

function validateSessionExportPayload(payload) {
  const sessionId = payload && payload.sessionId;
  if (typeof sessionId !== "string" || !SESSION_ID_PATTERN.test(sessionId)) {
    const error = new Error("sessionId is invalid");
    error.statusCode = 400;
    throw error;
  }
  if (payload.includeDescendants !== undefined && typeof payload.includeDescendants !== "boolean") {
    const error = new Error("includeDescendants must be boolean");
    error.statusCode = 400;
    throw error;
  }
  return {
    sessionId,
    includeDescendants: payload.includeDescendants !== false,
  };
}

function upstreamSessionExport(backend, request, sessionId, includeDescendants, authCookie) {
  return new Promise((resolve, reject) => {
    const query = new URLSearchParams({ sessionId });
    if (includeDescendants) query.set("includeDescendants", "true");
    const headers = buildHeaders(request.headers, backend, { gatewayAuthenticated: true });
    delete headers["content-length"];
    delete headers["transfer-encoding"];
    if (authCookie !== undefined) {
      headers.cookie = mergeBackendAuthCookie(headers.cookie, backendAuthCookieName(backend), authCookie);
    }
    headers.accept = "application/zip, application/octet-stream;q=0.9";
    const upstream = http.request(
      {
        host: backend.host,
        port: backend.port,
        method: "GET",
        path: `${SESSION_EXPORT_UPSTREAM_PATH}?${query.toString()}`,
        headers,
      },
      (response) => {
        const statusCode = response.statusCode || 502;
        if (statusCode < 200 || statusCode >= 300) {
          response.resume();
          response.once("end", () => {
            const error = new Error(`upstream session export failed (HTTP ${statusCode})`);
            error.statusCode = statusCode === 401 || statusCode === 403 ? statusCode : 502;
            reject(error);
          });
          return;
        }
        const contentLength = Number(response.headers["content-length"] || 0);
        if (Number.isFinite(contentLength) && contentLength > SESSION_EXPORT_MAX_BYTES) {
          response.resume();
          const error = new Error("session export is too large");
          error.statusCode = 413;
          reject(error);
          return;
        }
        resolve(response);
      },
    );
    upstream.once("error", reject);
    upstream.end();
  });
}

async function performSessionExport({ backend, request, sessionId, includeDescendants, authCookie }, envConfig) {
  if (!envConfig || !envConfig.workspaceRoot) {
    const error = new Error("workspace root is unavailable");
    error.statusCode = 503;
    throw error;
  }
  const exportRoot = path.join(envConfig.workspaceRoot, EXPORT_DIR_NAME);
  const destination = reserveExportDestination(
    exportRoot,
    `dsh-session-${sanitizeExportBasename(sessionId)}.zip`,
  );
  const temporaryDirectory = fs.mkdtempSync(path.join(exportRoot, ".dsh-session-"));
  const temporaryPath = path.join(temporaryDirectory, "archive.zip");
  let committed = false;
  const cleanup = () => {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
    if (!committed) fs.rmSync(destination, { force: true });
  };

  let upstreamResponse;
  try {
    upstreamResponse = await upstreamSessionExport(
      backend,
      request,
      sessionId,
      includeDescendants,
      authCookie,
    );
    await new Promise((resolve, reject) => {
      const output = fs.createWriteStream(temporaryPath, { flags: "wx" });
      let total = 0;
      let signature = Buffer.alloc(0);
      let settled = false;
      const fail = (error, statusCode = 502) => {
        if (settled) return;
        settled = true;
        if (error && !error.statusCode) error.statusCode = statusCode;
        output.destroy();
        upstreamResponse.destroy();
        reject(error || new Error("session export failed"));
      };
      output.once("error", (error) => fail(error));
      upstreamResponse.once("error", (error) => fail(error));
      upstreamResponse.on("data", (chunk) => {
        total += chunk.length;
        if (total > SESSION_EXPORT_MAX_BYTES) {
          const error = new Error("session export is too large");
          error.statusCode = 413;
          fail(error, 413);
          return;
        }
        if (signature.length < 4) {
          signature = Buffer.concat([signature, chunk]).subarray(0, 4);
        }
        if (!output.write(chunk)) upstreamResponse.pause();
      });
      output.on("drain", () => upstreamResponse.resume());
      upstreamResponse.once("end", () => {
        if (settled) return;
        output.end(() => {
          if (signature.length < 2 || signature[0] !== 0x50 || signature[1] !== 0x4b) {
            const error = new Error("upstream session export was not a ZIP archive");
            error.statusCode = 502;
            fail(error, 502);
            return;
          }
          try {
            fs.renameSync(temporaryPath, destination);
            committed = true;
            settled = true;
            resolve();
          } catch (error) {
            fail(error);
          }
        });
      });
    });
  } catch (error) {
    cleanup();
    throw error;
  }
  cleanup();
  return destination;
}

async function handleSessionExportRequest(request, response, { backend, envConfig, getAuthCookie }) {
  const exportUpstreamSession = async (authCookie) => {
    const result = await performSessionExport(
      { backend, request, ...payload, authCookie },
      envConfig,
    );
    return result;
  };
  const respond = (statusCode, payload) => {
    response.writeHead(statusCode, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(`${JSON.stringify(payload)}\n`);
  };
  if (request.method !== "POST") {
    respond(405, { error: "method not allowed" });
    return;
  }
  const { overflow, body } = await readJsonBody(request, SESSION_EXPORT_BODY_LIMIT);
  if (overflow) {
    respond(413, { error: "request body too large" });
    return;
  }
  let payload;
  try {
    payload = validateSessionExportPayload(JSON.parse(body.toString("utf8")));
  } catch (error) {
    respond(error && error.statusCode ? error.statusCode : 400, {
      error: error && error.message ? error.message : "invalid JSON body",
    });
    return;
  }
  const exportWithAuthRetry = async (getCookie, authRetry) => {
    let authCookie;
    if (getCookie) {
      try {
        authCookie = await getCookie();
      } catch (_) {
        respond(502, { error: "gateway authentication error" });
        return;
      }
    }
    try {
      const exportedPath = await exportUpstreamSession(authCookie);
      respond(200, { path: exportedPath });
    } catch (error) {
      const statusCode = error && error.statusCode ? error.statusCode : 500;
      // A stale gateway session surfaces as 401/403 from the export route:
      // one refresh+replay, then the rejection is final.
      if (
        authRetry
        && getCookie
        && authCookie !== undefined
        && (statusCode === 401 || statusCode === 403)
      ) {
        try {
          const freshCookie = await getCookie(true);
          const exportedPath = await exportUpstreamSession(freshCookie);
          respond(200, { path: exportedPath });
          return;
        } catch (retryError) {
          const retryStatus = retryError && retryError.statusCode ? retryError.statusCode : 502;
          respond(retryStatus, {
            error: retryError && retryError.message ? retryError.message : "session export failed",
          });
          return;
        }
      }
      respond(statusCode, {
        error: error && error.message ? error.message : "session export failed",
      });
    }
  };
  await exportWithAuthRetry(getAuthCookie, Boolean(getAuthCookie));
}

function serveLocalJavaScript(response, filePath, cacheControl) {
  let body;
  try {
    body = fs.readFileSync(filePath);
  } catch (_) {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found.\n");
    return;
  }
  response.writeHead(200, {
    "content-type": "application/javascript; charset=utf-8",
    "cache-control": cacheControl,
  });
  response.end(body);
}

function watchBackendProcess({ server, socketPath, backendPid, intervalMs = 1000, onBackendExit }) {
  if (!Number.isInteger(backendPid) || backendPid < 1) throw new Error("backend pid is required");
  let stopped = false;
  let timer;
  const finish = () => {
    if (stopped) return;
    stopped = true;
    clearInterval(timer);
    fs.rmSync(socketPath, { force: true });
    if (typeof onBackendExit === "function") onBackendExit();
  };
  timer = setInterval(() => {
    if (!isProcessRunning(backendPid)) {
      server.close(() => finish());
      if (typeof server.closeAllConnections === "function") server.closeAllConnections();
      setTimeout(finish, Math.max(intervalMs * 2, 100));
    }
  }, intervalMs);
  timer.unref();
  server.once("close", () => {
    if (!stopped) clearInterval(timer);
  });
  return () => {
    stopped = true;
    clearInterval(timer);
  };
}

function runtimeAdapterScript(gatewayPrefix, dynamicPrefixes) {
  const prefixJson = JSON.stringify(gatewayPrefix);
  const rootsJson = JSON.stringify(rewritePrefixes(dynamicPrefixes));
  return `/* ${MARKER}: browser routes */
(function () {
  var gatewayPrefix = ${prefixJson};
  var roots = ${rootsJson};
  function rewrite(value) {
    var source = typeof value === "string"
      ? value
      : (typeof URL !== "undefined" && value instanceof URL ? value.href : null);
    if (source === null) return value;
    var parsed;
    try { parsed = new URL(source, window.location.href); } catch (_) { return value; }
    var websocketProtocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    var sameWebSocketOrigin = parsed.protocol === websocketProtocol
      && parsed.host === window.location.host;
    if (parsed.origin !== window.location.origin && !sameWebSocketOrigin) return value;
    var pathname = parsed.pathname;
    var normalizedDuplicatePrefix = false;
    while (pathname.indexOf(gatewayPrefix + gatewayPrefix) === 0) {
      pathname = pathname.slice(gatewayPrefix.length);
      parsed.pathname = pathname;
      normalizedDuplicatePrefix = true;
    }
    for (var i = 0; i < roots.length; i += 1) {
      if (pathname.indexOf(gatewayPrefix + roots[i]) === 0) {
        return normalizedDuplicatePrefix ? parsed.toString() : value;
      }
      var root = roots[i];
      if (pathname !== root.slice(0, -1) && pathname.indexOf(root) !== 0) continue;
      parsed.pathname = gatewayPrefix + pathname;
      return parsed.toString();
    }
    return normalizedDuplicatePrefix ? parsed.toString() : value;
  }
  if (typeof window.fetch === "function") {
    var nativeFetch = window.fetch;
    window.fetch = function (input, init) {
      if (typeof Request !== "undefined" && input instanceof Request) {
        var rewrittenRequest = rewrite(input.url);
        if (rewrittenRequest !== input.url) input = new Request(rewrittenRequest, input);
      } else {
        input = rewrite(input);
      }
      return nativeFetch.call(this, input, init);
    };
  }
  if (typeof XMLHttpRequest !== "undefined") {
    var nativeOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      var args = Array.prototype.slice.call(arguments);
      args[1] = rewrite(url);
      return nativeOpen.apply(this, args);
    };
  }
  if (typeof WebSocket !== "undefined") {
    var NativeWebSocket = WebSocket;
    var GatewayWebSocket = function (url, protocols) {
      var rewritten = rewrite(url);
      return protocols === undefined
        ? new NativeWebSocket(rewritten)
        : new NativeWebSocket(rewritten, protocols);
    };
    GatewayWebSocket.prototype = NativeWebSocket.prototype;
    try { Object.setPrototypeOf(GatewayWebSocket, NativeWebSocket); } catch (_) {}
    window.WebSocket = GatewayWebSocket;
  }
  if (typeof EventSource !== "undefined") {
    var NativeEventSource = EventSource;
    var GatewayEventSource = function (url, config) {
      var rewritten = rewrite(url);
      return config === undefined
        ? new NativeEventSource(rewritten)
        : new NativeEventSource(rewritten, config);
    };
    GatewayEventSource.prototype = NativeEventSource.prototype;
    try { Object.setPrototypeOf(GatewayEventSource, NativeEventSource); } catch (_) {}
    window.EventSource = GatewayEventSource;
  }
})();\n`;
}

function isHtmlContentType(contentType) {
  const mediaType = String(contentType || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  return mediaType === "text/html" || mediaType === "application/xhtml+xml";
}

function rewriteBody(
  body,
  gatewayPrefix,
  dynamicPrefixes = [],
  contentType = "",
  envConfig = readFnosEnvConfig(),
  upstreamPath = "",
) {
  let output = body;
  const pathname = upstreamPath.split("?", 1)[0];
  const summaryClient = pathname === `/plugins/${SUMMARY_CLIENT_ROUTE}`
    || (pathname === "/plugins/" && upstreamPath.includes(SUMMARY_CLIENT_ROUTE));
  if (summaryClient && /javascript/i.test(contentType)) {
    output = rewriteChangesSummaryClient(output);
  }
  const htmlResponse = isHtmlContentType(contentType);
  if (htmlResponse && /<html/i.test(output) && output.includes(MARKER)) return output;
  const prefixes = rewritePrefixes(dynamicPrefixes);

  output = rewritePluginManagerLoopback(output);
  output = rewriteRemoteWebUiLoopback(output);
  output = rewriteBetterSidebarWebSocketResilience(output);
  output = rewriteMobileUiRegistration(output);
  output = rewriteSettingsHostPersistence(output);
  output = output
    .split("/^\\/[A-Za-z0-9._~-]+$/")
    .join("/^\\/[\\w./-]+$/");

  for (const pathPrefix of prefixes) {
    for (const boundary of ['"', "'", "`", "(", " ", "="]) {
      output = output
        .split(`${boundary}${pathPrefix}`)
        .join(`${boundary}${gatewayPrefix}${pathPrefix}`);
    }
  }
  output = output
    .split(`${gatewayPrefix}${gatewayPrefix}`)
    .join(gatewayPrefix);

  // dsh-api-gateway resolves the mux route relative to document.baseURI, so a
  // prefixed constant would double the unified-gateway path at runtime. The
  // guard looks for any quoted gateway-prefixed mux path so minified or
  // refactored bundles are still recognized.
  if (output.includes("/api/remote.mux")) {
    for (const boundary of ['"', "'", "`"]) {
      output = output
        .split(`${boundary}${gatewayPrefix}/api/remote.mux${boundary}`)
        .join(`${boundary}/api/remote.mux${boundary}`);
    }
  }

  if (htmlResponse && /<html/i.test(output) && !output.includes(MARKER)) {
    const adapter = runtimeAdapterScript(gatewayPrefix, dynamicPrefixes);
    const configJson = JSON.stringify(fnosBrowserConfig(gatewayPrefix, envConfig))
      .replace(/</g, "\\u003c");
    const injection =
      `<!-- ${MARKER} -->` +
      `<base href="${gatewayPrefix}/">` +
      `<script>window.__DSH_FNOS__=${configJson};</script>` +
      `<script src="${gatewayPrefix}${POLYFILL_PATH}"></script>` +
      `<script src="${gatewayPrefix}${TRIM_WEB_APP_PATH}"></script>` +
      `<script src="${gatewayPrefix}${FNOS_OPEN_ENHANCER_PATH}"></script>` +
      (adapter ? `<script>${adapter}</script>` : "");
    output = output.replace(/<head([^>]*)>/i, `<head$1>${injection}`);
  }
  return output;
}

function writeSocketError(socket, status, message) {
  const body = `${message}\n`;
  socket.end(
    `HTTP/1.1 ${status}\r\n` +
      "Content-Type: text/plain; charset=utf-8\r\n" +
      `Content-Length: ${Buffer.byteLength(body)}\r\n` +
      "Connection: close\r\n\r\n" +
      body,
    () => socket.destroy()
  );
}

function startGatewayProxy({
  socketPath,
  gatewayPrefix,
  target,
  compatPath,
  profilesRoot,
  authTokenPath,
  backendPid,
  websocketHandshakeTimeoutMs = 10000,
  websocketWriteStallTimeoutMs = 45000,
}) {
  if (!socketPath) throw new Error("socket path is required");
  validateTimeout(websocketHandshakeTimeoutMs, "WebSocket handshake timeout");
  validateTimeout(websocketWriteStallTimeoutMs, "WebSocket write stall timeout");
  const prefix = normalizePrefix(gatewayPrefix);
  const backend = typeof target === "string" ? parseTarget(target) : target;
  // Startup stays strict (a malformed token file must fail fast), while later
  // acquisitions re-read the file so a rotated token recovers without restart.
  const launchToken = authTokenPath ? readLaunchToken(authTokenPath) : undefined;
  const readLaunchTokenSafely = () => {
    try {
      return readLaunchToken(authTokenPath);
    } catch (_) {
      return undefined;
    }
  };
  const authCookieName = backendAuthCookieName(backend);
  let backendAuthCookiePromise;
  // Force the next acquisition to re-read the token file and re-exchange, so
  // a rotated launch token or an invalidated backend session recovers without
  // a gateway restart.
  const refreshBackendAuthCookie = () => {
    backendAuthCookiePromise = undefined;
  };
  const acquireBackendAuthCookie = (token) => {
    backendAuthCookiePromise = requestBackendAuthCookie(backend, token, authCookieName)
      .catch((error) => {
        backendAuthCookiePromise = undefined;
        throw error;
      });
    return backendAuthCookiePromise;
  };
  const getBackendAuthCookie = () => {
    if (backendAuthCookiePromise === undefined) {
      // Prefer the current file contents so a rotated token is picked up on
      // every fresh acquisition; fall back to the startup token if the file
      // is temporarily unreadable.
      const token = readLaunchTokenSafely() ?? launchToken;
      if (token === undefined) return Promise.resolve(undefined);
      acquireBackendAuthCookie(token);
    }
    return backendAuthCookiePromise;
  };
  const getFreshBackendAuthCookie = () => {
    refreshBackendAuthCookie();
    return getBackendAuthCookie();
  };
  // Session export passes refresh=true to force a new exchange after a
  // 401/403 from the export route.
  const getBackendAuthCookieWithRefresh = (refresh) => (
    refresh ? getFreshBackendAuthCookie() : getBackendAuthCookie()
  );
  const server = http.createServer((request, response) => {
    if (!isAdminRequest(request.headers)) {
      response.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
      response.end("Administrator access is required.\n");
      return;
    }
    if (!isGatewayPath(request.url, prefix)) {
      response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      response.end("Not found.\n");
      return;
    }

    const targetPath = stripPrefix(request.url || "/", prefix);
    const localPathname = targetPath.split("?", 1)[0];
    if (localPathname === POLYFILL_PATH) {
      response.writeHead(200, {
        "content-type": "application/javascript; charset=utf-8",
        "cache-control": "public, max-age=86400",
      });
      response.end(RANDOM_UUID_POLYFILL);
      return;
    }
    if (localPathname === FNOS_OPEN_ENHANCER_PATH) {
      serveLocalJavaScript(response, FNOS_OPEN_ENHANCER_FILE, "no-store");
      return;
    }
    if (localPathname === TRIM_WEB_APP_PATH) {
      serveLocalJavaScript(response, TRIM_WEB_APP_FILE, "public, max-age=86400");
      return;
    }
    if (localPathname === EXPORT_OPEN_PATH) {
      handleExportOpenRequest(request, response, readFnosEnvConfig())
        .catch(() => {
          if (!response.headersSent) {
            response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
          }
          response.end("Export endpoint error.\n");
        });
      return;
    }
    if (localPathname === PATH_STAT_PATH) {
      handlePathStatRequest(request, response, readFnosEnvConfig())
        .catch(() => {
          if (!response.headersSent) {
            response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
          }
          response.end("Stat endpoint error.\n");
        });
      return;
    }
    if (localPathname === SESSION_EXPORT_PATH) {
      handleSessionExportRequest(request, response, {
        backend,
        envConfig: readFnosEnvConfig(),
        // Session export reaches a backend route that requires the gateway
        // session when browser auth is enabled; share the cached cookie.
        getAuthCookie: authTokenPath ? getBackendAuthCookieWithRefresh : undefined,
      }).catch(() => {
        if (!response.headersSent) {
          response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
        }
        response.end("Session export endpoint error.\n");
      });
      return;
    }

    const rootGet = request.method === "GET"
      && new URL(targetPath, "http://gateway.invalid").pathname === "/";
    const cleanTargetPath = rootGet ? rootPathWithoutClientToken(targetPath) : targetPath;
    const browserHasAuthCookie = hasCookie(request.headers.cookie, authCookieName);

    const forward = (upstreamPath, retryAuthentication, backendAuthCookie, authRetry) => {
      const headers = buildHeaders(request.headers, backend, {
        gatewayAuthenticated: true,
        // The adapter decision is only known after reading the upstream body.
        disableRevalidation:
          request.method === "GET" && isAdaptedPluginClientPath(upstreamPath),
      });
      if (backendAuthCookie !== undefined) {
        headers.cookie = mergeBackendAuthCookie(headers.cookie, authCookieName, backendAuthCookie);
      }
      const proxyRequest = http.request(
        {
          host: backend.host,
          port: backend.port,
          method: request.method,
          path: upstreamPath,
          headers,
        },
        (proxyResponse) => {
          if (retryAuthentication && proxyResponse.statusCode === 401 && launchToken !== undefined) {
            proxyResponse.resume();
            proxyResponse.once("end", () => {
              forward(tokenExchangePath(cleanTargetPath, launchToken), false);
            });
            return;
          }
          // A non-root request carrying the gateway session was rejected:
          // the cached backend cookie is stale. Refresh once, then replay;
          // a second rejection is surfaced to the browser untouched. Only
          // bodyless replays are safe: a streamed request body cannot be
          // rewound once piped to the rejected upstream attempt.
          if (authRetry
            && request.method === "GET"
            && (proxyResponse.statusCode === 401 || proxyResponse.statusCode === 403)) {
            proxyResponse.resume();
            proxyResponse.once("end", () => {
              getFreshBackendAuthCookie()
                .then((freshCookie) => {
                  if (request.destroyed || response.destroyed) return;
                  forward(cleanTargetPath, false, freshCookie);
                })
                .catch(() => {
                  if (!response.headersSent) {
                    response.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
                  }
                  response.end("Gateway authentication error.\n");
                });
            });
            return;
          }
        const dynamicPrefixes = readDynamicPrefixes(compatPath);
        const contentType = String(proxyResponse.headers["content-type"] || "");
        const contentLength = Number(proxyResponse.headers["content-length"] || 0);
        const textResponse = /text\/|javascript|json|xml/i.test(contentType);
        const shouldRewrite = textResponse && (!contentLength || contentLength <= MAX_REWRITE_BYTES);
        const headers = { ...proxyResponse.headers };
        if (headers.location) headers.location = rewriteLocation(headers.location, prefix, dynamicPrefixes);
        if (headers["set-cookie"]) {
          headers["set-cookie"] = rewriteSetCookie(headers["set-cookie"], prefix);
        }

        if (!shouldRewrite) {
          response.writeHead(proxyResponse.statusCode || 502, headers);
          proxyResponse.pipe(response);
          return;
        }

        const chunks = [];
        let bytes = 0;
        proxyResponse.on("data", (chunk) => {
          bytes += chunk.length;
          chunks.push(chunk);
        });
        proxyResponse.on("end", () => {
          const original = Buffer.concat(chunks, bytes);
          const originalText = original.toString("utf8");
          const rewrittenText = rewriteBody(originalText, prefix, dynamicPrefixes, contentType, readFnosEnvConfig(), upstreamPath);
          const rewritten = Buffer.from(rewrittenText, "utf8");
          delete headers["content-length"];
          delete headers["content-encoding"];
          delete headers["transfer-encoding"];
          if (rewrittenText !== originalText) {
            delete headers.etag;
            delete headers["last-modified"];
            delete headers.expires;
            delete headers.age;
            headers["cache-control"] = "no-store";
          }
          headers["content-length"] = String(rewritten.length);
          response.writeHead(proxyResponse.statusCode || 502, headers);
          response.end(rewritten);
        });
        },
      );

      proxyRequest.on("error", (error) => {
        if (!response.headersSent) {
          response.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
        }
        response.end(`Gateway proxy error: ${error.message}\n`);
      });
      // Replay after an auth refresh reuses an already-consumed request
      // stream: piping it again never reaches end, so finish bodyless
      // replays directly. `complete` covers a fully-received request whose
      // Readable has already been drained by the first forward attempt.
      if (rootGet || request.complete) proxyRequest.end();
      else request.pipe(proxyRequest);
    };

    if (rootGet && launchToken !== undefined && !browserHasAuthCookie) {
      forward(tokenExchangePath(cleanTargetPath, launchToken), false);
    } else if (!rootGet && launchToken !== undefined) {
      getBackendAuthCookie()
        .then((backendAuthCookie) => {
          if (request.destroyed || response.destroyed) return;
          forward(cleanTargetPath, false, backendAuthCookie, true);
        })
        .catch(() => {
          if (!response.headersSent) {
            response.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
          }
          response.end("Gateway authentication error.\n");
        });
    } else {
      forward(cleanTargetPath, rootGet && launchToken !== undefined);
    }
  });

  server.on("upgrade", (request, socket, head) => {
    if (!isAdminRequest(request.headers)) {
      writeSocketError(socket, "403 Forbidden", "Administrator access is required.");
      return;
    }
    if (!isGatewayPath(request.url, prefix)) {
      writeSocketError(socket, "404 Not Found", "Not found.");
      return;
    }
    const targetPath = stripPrefix(request.url || "/", prefix);
    if (head && head.length > 64 * 1024) {
      writeSocketError(socket, "502 Bad Gateway", "Client pre-upgrade data exceeded 64 KiB.");
      return;
    }
    socket.pause();
    // True if the upstream handshake bytes mark success (101). Any HTTP error
    // reply means the upgrade was rejected; a 401/403 with an auth cookie
    // points at a stale cached session.
    const connect = (backendAuthCookie, authRetry, pendingClient = Buffer.alloc(0)) => {
      if (socket.destroyed) return;
      const upstream = net.connect(backend.port, backend.host, () => {
        const headers = buildHeaders(request.headers, backend, { upgrade: true, gatewayAuthenticated: true });
        if (backendAuthCookie !== undefined) {
          headers.cookie = mergeBackendAuthCookie(headers.cookie, authCookieName, backendAuthCookie);
        }
        const headerLines = Object.entries(headers).map(([name, value]) => `${name}: ${value}`);
        upstream.write(`${request.method} ${targetPath} HTTP/1.1\r\n${headerLines.join("\r\n")}\r\n\r\n`);
        if (head && head.length) upstream.write(head);
      });
      // Inspect the upstream handshake before piping: 101 continues with the
      // buffered bytes in both directions, 401/403 with a gateway cookie
      // refreshes once, other replies surface to the browser.
      let handshakeStatus;
      let upstreamBuffered = Buffer.alloc(0);
      let clientBuffered = pendingClient;
      let handshakeTimer;
      const onClientClose = () => {
        detachHandshake();
        upstream.destroy();
        socket.destroy();
      };
      const failHandshake = (message) => {
        detachHandshake();
        upstream.destroy();
        if (!socket.destroyed) writeSocketError(socket, "502 Bad Gateway", message);
      };
      const onUpstreamError = () => failHandshake("Upstream WebSocket handshake failed.");
      const onUpstreamClose = () => failHandshake("Upstream closed before WebSocket upgrade.");
      const onClientData = (chunk) => {
        if (clientBuffered.length + chunk.length > 64 * 1024) {
          failHandshake("Client pre-upgrade data exceeded 64 KiB.");
          return;
        }
        clientBuffered = Buffer.concat([clientBuffered, chunk]);
      };
      const detachHandshake = () => {
        clearTimeout(handshakeTimer);
        socket.off("data", onClientData);
        socket.pause();
        socket.off("close", onClientClose);
        socket.off("end", onClientClose);
        socket.off("error", onClientClose);
        socket.once("error", () => {});
        upstream.off("data", onUpstreamData);
        upstream.off("error", onUpstreamError);
        upstream.off("close", onUpstreamClose);
        // A cancelled connect/write may still emit an error while destroy settles.
        upstream.once("error", () => {});
      };
      const onUpstreamData = (chunk) => {
        upstreamBuffered = Buffer.concat([upstreamBuffered, chunk]);
        const headerEnd = upstreamBuffered.indexOf("\r\n\r\n");
        if ((headerEnd === -1 ? upstreamBuffered.length : headerEnd + 4) > 64 * 1024) {
          failHandshake("Upstream handshake header exceeded 64 KiB.");
          return;
        }
        if (headerEnd === -1) return;
        const statusLine = upstreamBuffered.subarray(0, upstreamBuffered.indexOf("\r\n")).toString("latin1");
        const statusMatch = /^HTTP\/1\.[01] (\d{3})/.exec(statusLine);
        handshakeStatus = statusMatch ? Number(statusMatch[1]) : 502;
        if ((handshakeStatus === 401 || handshakeStatus === 403)
          && authRetry
          && backendAuthCookie !== undefined) {
          detachHandshake();
          upstream.destroy();
          getFreshBackendAuthCookie()
            .then((freshCookie) => connect(freshCookie, false, clientBuffered))
            .catch(() => writeSocketError(socket, "502 Bad Gateway", "Gateway authentication error."));
          return;
        }
        if (handshakeStatus !== 101) {
          detachHandshake();
          socket.end(upstreamBuffered, () => socket.destroy());
          upstream.destroy();
          return;
        }
        detachHandshake();
        relayWebSocket(socket, upstream, {
          serverHead: upstreamBuffered,
          clientHead: clientBuffered,
          writeStallTimeoutMs: websocketWriteStallTimeoutMs,
          onStall: ({ direction, bufferedBytes }) => {
            process.stderr.write(`WebSocket ${direction} write stalled with ${bufferedBytes} buffered bytes; relay closed.\n`);
          },
        });
      };
      handshakeTimer = setTimeout(() => failHandshake("Upstream WebSocket handshake timed out."), websocketHandshakeTimeoutMs);
      handshakeTimer.unref();
      socket.on("data", onClientData);
      socket.once("close", onClientClose);
      socket.once("end", onClientClose);
      socket.once("error", onClientClose);
      upstream.on("data", onUpstreamData);
      upstream.once("error", onUpstreamError);
      upstream.once("close", onUpstreamClose);
      socket.resume();
    };
    if (launchToken === undefined) {
      connect(undefined);
      return;
    }
    getBackendAuthCookie()
      .then((cookie) => connect(cookie, true))
      .catch(() => writeSocketError(socket, "502 Bad Gateway", "Gateway authentication error."));
  });

  fs.rmSync(socketPath, { force: true });
  server.listen(socketPath, () => {
    process.stdout.write(
      `DeepSeek Harness gateway proxy: ${socketPath} -> ${backend.host}:${backend.port}\n`
    );
  });
  if (backendPid !== undefined) {
    watchBackendProcess({
      server,
      socketPath,
      backendPid,
      onBackendExit: () => {
        process.stderr.write("DeepSeek Harness backend exited; gateway proxy is stopping.\n");
        process.exitCode = 1;
      },
    });
  }
  return server;
}

if (require.main === module) {
  const socketPath = process.argv[2];
  const gatewayPrefix = process.argv[3];
  const target = process.argv[4];
  const compatPath = process.argv[5];
  const profilesRoot = process.argv[6];
  const authTokenPath = process.argv[7];
  const backendPid = process.argv[8] === undefined ? undefined : parsePid(process.argv[8]);
  try {
    if (!socketPath || !gatewayPrefix || !target) {
      throw new Error("usage: gateway-proxy.js <socketPath> <gatewayPrefix> <127.0.0.1:port> [compatPath] [profilesRoot] [authTokenPath] [backendPid]");
    }
    startGatewayProxy({ socketPath, gatewayPrefix, target, compatPath, profilesRoot, authTokenPath, backendPid });
  } catch (error) {
    process.stderr.write(`${error.stack || error.message}\n`);
    process.exit(1);
  }
}

module.exports = {
  BETTER_SIDEBAR_CLIENT_ROUTES,
  BETTER_SIDEBAR_CONTAINER_MARKERS,
  BETTER_SIDEBAR_WS_MARKER,
  MARKER,
  MOBILE_UI_CLIENT_ROUTE,
  MOBILE_UI_MARKERS,
  PLUGIN_MANAGER_MARKER,
  REMOTE_WEB_UI_CONTAINER_MARKERS,
  REMOTE_WEB_UI_MARKERS,
  SETTINGS_CLIENT_MARKER,
  POLYFILL_PATH,
  FNOS_OPEN_ENHANCER_PATH,
  TRIM_WEB_APP_PATH,
  EXPORT_OPEN_PATH,
  PATH_STAT_PATH,
  SESSION_EXPORT_PATH,
  SESSION_EXPORT_UPSTREAM_PATH,
  EXPORT_DIR_NAME,
  BUILTIN_REWRITE_PREFIXES,
  RANDOM_UUID_POLYFILL,
  buildHeaders,
  backendAuthCookieName,
  fnosBrowserConfig,
  handleExportOpenRequest,
  handlePathStatRequest,
  statProbeIsDirectory,
  handleSessionExportRequest,
  isAdminRequest,
  isAdaptedPluginClientPath,
  isGatewayPath,
  isHtmlContentType,
  isPathWithinRoot,
  normalizePrefix,
  parseTarget,
  parsePid,
  performExportOpen,
  performSessionExport,
  pickExportDestination,
  reserveExportDestination,
  readFnosEnvConfig,
  readLaunchToken,
  isProcessRunning,
  readDynamicPrefixes,
  rewriteBody,
  rewriteBetterSidebarWebSocketResilience,
  rewriteMobileUiRegistration,
  rewritePluginManagerLoopback,
  rewriteRemoteWebUiLoopback,
  rewriteSettingsHostPersistence,
  rewritePrefixes,
  resolveExportSource,
  validateSessionExportPayload,
  runtimeAdapterScript,
  sanitizeExportBasename,
  rewriteLocation,
  rewriteSetCookie,
  rootPathWithoutClientToken,
  requestBackendAuthCookie,
  mergeBackendAuthCookie,
  startGatewayProxy,
  watchBackendProcess,
  stripPrefix,
  tokenExchangePath,
};
