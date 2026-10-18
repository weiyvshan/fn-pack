/* dsh-fnos-gateway-adapter: fnOS file and file-manager routing.
 *
 * This script is injected by the gateway proxy into the harness HTML shell. It
 * converts Session log exports into files in dsh-exports and opens them with
 * the fnOS Web file manager instead of the browser download manager. It also
 * replaces DSH's open-in-app catalog with the sole fnOS `filemanager` choice
 * in an iframe. Standalone pages receive no local apps, and stale editor
 * choices are rejected instead of reaching the NAS Host.
 *
 * Presented-file cards remain owned by DSH so their primary action continues
 * to open the native right Sidebar through `sidebarRight.openResource`.
 */
(function () {
  "use strict";

  var config = window.__DSH_FNOS__ || {};
  var prefix = String(config.prefix || "");
  var SDK_URL = String(config.sdkPath || prefix + "/__fnos/trim-web-app.js");
  var EXPORT_URL = String(config.exportPath || prefix + "/__fnos/export-open");
  var STAT_URL = String(config.statPath || prefix + "/__fnos/stat");
  var SESSION_EXPORT_URL = String(
    config.sessionExportPath || prefix + "/__fnos/export-session",
  );
  var VISIBLE_ROOTS = Array.isArray(config.visibleRoots) ? config.visibleRoots : [];
  var OPEN_IN_APP_APPS_PATH = "/open-in-app/apps";
  var OPEN_IN_APP_OPEN_PATH = "/open-in-app/open";
  var SIDEBAR_OPEN_EXTERNAL_PATH = "/sidebar/api/open.external";
  var FILE_MANAGER_APP_ID = "filemanager";
  var FETCH_ADAPTER_ATTR = "__DSH_FNOS_OPEN_IN_APP_FETCH__";
  var SIDEBAR_OPEN_EXTERNAL_ADAPTER_ATTR = "__DSH_FNOS_SIDEBAR_OPEN_EXTERNAL__";
  var SESSION_EXPORT_ADAPTER_ATTR = "__DSH_FNOS_SESSION_EXPORT__";
  var SESSION_EXPORT_UPSTREAM_PATH = "/api/session.export";
  var SESSION_EXPORT_PATHS = new Map();
  var SESSION_EXPORT_PROMISES = new Map();
  var configuredReadyTimeout = Number(config.sdkReadyTimeoutMs);
  var SDK_READY_TIMEOUT_MS = Number.isFinite(configuredReadyTimeout)
    && configuredReadyTimeout > 0
    ? Math.min(configuredReadyTimeout, 15000)
    : 5000;

  var sdkPromise = null;
  var sdkInstance = null;

  function withWebCarrierUserAgent(run) {
    if (typeof navigator === "undefined" || !isEmbeddedHost()
      || typeof navigator.userAgent !== "string") return run();
    var original = navigator.userAgent;
    if (!/\bFNAppVer\/[^\s)]+/i.test(original)) return run();
    var normalized = original.replace(/\s+FNAppVer\/[^\s)]+/gi, "");
    try {
      Object.defineProperty(navigator, "userAgent", {
        configurable: true,
        value: normalized,
      });
    } catch (_) {
      return run();
    }
    try {
      return run();
    } finally {
      try {
        Object.defineProperty(navigator, "userAgent", {
          configurable: true,
          value: original,
        });
      } catch (_) {}
    }
  }

  function withTimeout(promise, milliseconds) {
    return new Promise(function (resolve, reject) {
      var settled = false;
      var timer = window.setTimeout(function () {
        if (settled) return;
        settled = true;
        reject(new Error("fnOS Web 桥接在 " + milliseconds + "ms 内未就绪"));
      }, milliseconds);
      Promise.resolve(promise).then(function (value) {
        if (settled) return;
        settled = true;
        window.clearTimeout(timer);
        resolve(value);
      }, function (error) {
        if (settled) return;
        settled = true;
        window.clearTimeout(timer);
        reject(error);
      });
    });
  }

  function warn(message) {
    try { window.console.warn("[dsh-fnos-open] " + message); } catch (_) {}
  }

  function loadSdk() {
    if (sdkPromise) return sdkPromise;
    sdkPromise = new Promise(function (resolve, reject) {
      if (window.TrimAppSDK && window.TrimAppSDK.TrimApp) {
        resolve(window.TrimAppSDK.TrimApp);
        return;
      }
      var script = document.createElement("script");
      script.src = SDK_URL;
      script.onload = function () {
        if (window.TrimAppSDK && window.TrimAppSDK.TrimApp) resolve(window.TrimAppSDK.TrimApp);
        else reject(new Error("TrimAppSDK global missing after script load"));
      };
      script.onerror = function () {
        sdkPromise = null;
        reject(new Error("failed to load " + SDK_URL));
      };
      document.head.appendChild(script);
    });
    return sdkPromise;
  }

  function getOrCreateSdk(TrimApp) {
    if (!sdkInstance) {
      sdkInstance = withWebCarrierUserAgent(function () { return new TrimApp(); });
    }
    return sdkInstance;
  }

  function waitForSdk(sdk) {
    var ready = typeof sdk.ready === "function" ? sdk.ready() : Promise.resolve();
    return withTimeout(ready, SDK_READY_TIMEOUT_MS).then(function () {
      if (!sdk.isWeb || sdk.isStandaloneWeb) {
        throw new Error("fnOS Web 桌面桥接不可用（独立浏览器页面）");
      }
      return sdk;
    });
  }

  function ensureSdk() {
    return loadSdk().then(function (TrimApp) {
      return waitForSdk(getOrCreateSdk(TrimApp));
    });
  }

  function primeSdk() {
    if (!isEmbeddedHost()) return;
    var TrimApp = window.TrimAppSDK && window.TrimAppSDK.TrimApp;
    if (typeof TrimApp !== "function") {
      ensureSdk().catch(function (error) {
        warn("fnOS Web 桥接预热失败: " + ((error && error.message) || error));
      });
      return;
    }
    if (!sdkPromise) sdkPromise = Promise.resolve(TrimApp);
    var sdk;
    try {
      sdk = getOrCreateSdk(TrimApp);
    } catch (error) {
      warn("fnOS Web 桥接构造失败: " + ((error && error.message) || error));
      return;
    }
    waitForSdk(sdk).catch(function (error) {
      warn("fnOS Web 桥接预热失败: " + ((error && error.message) || error));
    });
  }

  function isEmbeddedHost() {
    try { return window.parent !== window; } catch (_) { return false; }
  }

  function isUserVisible(path) {
    for (var i = 0; i < VISIBLE_ROOTS.length; i += 1) {
      var root = String(VISIBLE_ROOTS[i] || "");
      if (root === "") continue;
      if (path.indexOf(root) === 0
        && (path.length === root.length || path.charAt(root.length) === "/")) return true;
    }
    return false;
  }

  function parentOfPath(p) {
    var trimmed = String(p).replace(/\/+$/, "");
    if (trimmed === "" || trimmed === "/") return "/";
    var idx = trimmed.lastIndexOf("/");
    if (idx <= 0) return "/";
    return trimmed.slice(0, idx);
  }

  // fnOS openFileManager 只接受目录导航；探测失败一律回退父目录。
  function statIsDirectory(path) {
    return fetch(STAT_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: path }),
    }).then(function (resp) {
      if (!resp.ok) return false;
      return resp.json();
    }).then(function (data) {
      return !!(data && data.isDir);
    }).catch(function () {
      return false;
    });
  }

  function callSdkOpen(sdk, method, path) {
    if (typeof sdk[method] !== "function") {
      throw new Error("sdk." + method + " is unavailable");
    }
    return sdk[method](path);
  }

  function exportThenOpen(path, sdk, method) {
    return fetch(EXPORT_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: path }),
    }).then(function (resp) {
      if (!resp.ok) throw new Error("导出失败（HTTP " + resp.status + "）");
      return resp.json();
    }).then(function (data) {
      if (!data || typeof data.path !== "string" || data.path === "") {
        throw new Error("导出响应缺少路径");
      }
      // 导出物恒为文件，fnOS 文件管理器只能导航目录，打开导出目录。
      return callSdkOpen(sdk, method, parentOfPath(data.path));
    });
  }

  function openPath(path, method) {
    return ensureSdk().then(function (sdk) {
      if (isUserVisible(path)) return callSdkOpen(sdk, method, path);
      return exportThenOpen(path, sdk, method);
    });
  }

  // reveal（资源管理器）适配：目录打开自身，文件打开所在目录，
  // 不可见路径导出后打开导出目录；探测失败一律按文件回退。
  function revealOpen(path) {
    return statIsDirectory(path).then(function (isDir) {
      if (isDir && isUserVisible(path)) {
        return openPath(path, "openFileManager");
      }
      if (isUserVisible(path)) {
        return openPath(parentOfPath(path), "openFileManager");
      }
      return ensureSdk().then(function (sdk) {
        return exportThenOpen(path, sdk, "openFileManager");
      });
    });
  }

  function sessionExportDetails(input) {
    var source = requestUrl(input);
    if (source === null) return null;
    try {
      var parsed = new URL(source, window.location.href);
      var currentOrigin = new URL(window.location.href).origin;
      if (parsed.origin !== currentOrigin) return null;
      if (parsed.pathname !== SESSION_EXPORT_UPSTREAM_PATH
        && parsed.pathname !== prefix + SESSION_EXPORT_UPSTREAM_PATH) return null;
      var sessionId = parsed.searchParams.get("sessionId");
      if (!sessionId) return null;
      return {
        sessionId: sessionId,
        includeDescendants: parsed.searchParams.get("includeDescendants") !== "false",
      };
    } catch (_) { return null; }
  }

  function sessionExportResponsePath(response) {
    if (!response || !response.ok || typeof response.clone !== "function") {
      return Promise.reject(new Error("Session 日志导出失败（HTTP "
        + ((response && response.status) || 502) + "）"));
    }
    return response.clone().json().then(function (payload) {
      if (!payload || typeof payload.path !== "string" || payload.path === "") {
        throw new Error("Session 日志导出响应缺少路径");
      }
      return payload.path;
    });
  }

  function requestSessionExport(sessionId, includeDescendants, fetcher) {
    var key = String(sessionId);
    var existing = SESSION_EXPORT_PROMISES.get(key);
    if (existing) return existing;
    var promise = fetcher(SESSION_EXPORT_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ sessionId: key, includeDescendants: includeDescendants !== false }),
    }).then(sessionExportResponsePath);
    SESSION_EXPORT_PROMISES.set(key, promise);
    promise.then(function () {
      SESSION_EXPORT_PROMISES.delete(key);
    }, function () {
      SESSION_EXPORT_PROMISES.delete(key);
    });
    return promise;
  }

  function interceptSessionDownload(anchor) {
    if (!anchor || !anchor.download) return false;
    var details = sessionExportDetails(anchor.href || anchor.getAttribute("href"));
    if (!details) return false;
    var exportedPath = SESSION_EXPORT_PATHS.get(details.sessionId);
    SESSION_EXPORT_PATHS.delete(details.sessionId);
    var fetcher = typeof window.fetch === "function"
      ? window.fetch.bind(window)
      : null;
    var exportPromise = exportedPath
      ? Promise.resolve(exportedPath)
      : (fetcher
        ? requestSessionExport(details.sessionId, details.includeDescendants, fetcher)
        : Promise.reject(new Error("浏览器 Fetch 不可用")));
    exportPromise.then(function (path) {
      return openPath(parentOfPath(path), "openFileManager");
    }).catch(function (error) {
      warn("session export open failed for " + details.sessionId + ": "
        + ((error && error.message) || error));
    });
    return true;
  }

  function installSessionExportAdapter() {
    if (!isEmbeddedHost() || typeof window.fetch !== "function"
      || window[SESSION_EXPORT_ADAPTER_ATTR]) return;
    var nativeFetch = window.fetch;
    window[SESSION_EXPORT_ADAPTER_ATTR] = true;
    window.fetch = function (input, init) {
      var receiver = this;
      var method = requestMethod(input, init);
      var details = method === "HEAD" ? sessionExportDetails(input) : null;
      if (!details) return nativeFetch.call(receiver, input, init);
      return requestSessionExport(
        details.sessionId,
        details.includeDescendants,
        nativeFetch.bind(receiver),
      ).then(function (exportedPath) {
        SESSION_EXPORT_PATHS.set(details.sessionId, exportedPath);
        return successfulOpenResponse();
      });
    };
  }

  function installSessionDownloadAnchorAdapter() {
    if (!isEmbeddedHost() || !document || typeof document.createElement !== "function"
      || document[SESSION_EXPORT_ADAPTER_ATTR]) return;
    var nativeCreateElement = document.createElement.bind(document);
    document[SESSION_EXPORT_ADAPTER_ATTR] = true;
    document.createElement = function (tagName, options) {
      var element = nativeCreateElement(tagName, options);
      if (String(tagName).toLowerCase() !== "a" || !element
        || typeof element.click !== "function") return element;
      var nativeClick = element.click.bind(element);
      element.click = function () {
        if (interceptSessionDownload(element)) return;
        return nativeClick.apply(element, arguments);
      };
      return element;
    };
  }

  function requestUrl(input) {
    if (typeof input === "string") return input;
    if (input && typeof input.url === "string") return input.url;
    if (input && typeof input.href === "string") return input.href;
    return null;
  }

  function requestPath(input) {
    var source = requestUrl(input);
    if (source === null) return null;
    try {
      var parsed = new URL(source, window.location.href);
      var currentOrigin = new URL(window.location.href).origin;
      return parsed.origin === currentOrigin ? parsed.pathname : null;
    } catch (_) { return null; }
  }

  function matchesOpenInAppPath(input, route) {
    var pathname = requestPath(input);
    return pathname === route || pathname === prefix + route;
  }

  function requestMethod(input, init) {
    return String((init && init.method) || (input && input.method) || "GET").toUpperCase();
  }

  function requestBodyText(input, init) {
    if (init && typeof init.body === "string") return Promise.resolve(init.body);
    if (typeof Request !== "undefined" && input instanceof Request) {
      try { return input.clone().text(); } catch (_) { return Promise.resolve(null); }
    }
    return Promise.resolve(null);
  }

  function fnosFileManagerAppsResponse(embedded) {
    var apps = embedded ? [FILE_MANAGER_APP_ID] : [];
    if (typeof Response === "function") {
      return new Response(JSON.stringify({ apps: apps }), {
        status: 200,
        headers: {
          "content-type": "application/json; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }
    return { ok: true, status: 200, json: function () {
      return Promise.resolve({ apps: apps });
    } };
  }

  function openErrorResponse(code, message, status) {
    if (typeof Response === "function") {
      return new Response(JSON.stringify({ error: code, message: message }), {
        status: status || 400,
        headers: {
          "content-type": "application/json; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }
    return { ok: false, status: status || 400, json: function () {
      return Promise.resolve({ error: code, message: message });
    } };
  }

  function successfulOpenResponse() {
    if (typeof Response === "function") {
      return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
    }
    return { ok: true, status: 204 };
  }

  function sidebarOpenOkResponse() {
    if (typeof Response === "function") {
      return new Response(JSON.stringify({ ok: true, value: { started: true } }), {
        status: 200,
        headers: {
          "content-type": "application/json; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }
    return { ok: true, status: 200, json: function () {
      return Promise.resolve({ ok: true, value: { started: true } });
    } };
  }

  function sidebarOpenErrorResponse(code, message, status) {
    if (typeof Response === "function") {
      return new Response(
        JSON.stringify({ ok: false, error: { code: code, message: message } }),
        {
          status: status || 400,
          headers: {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
          },
        },
      );
    }
    return { ok: false, status: status || 400, json: function () {
      return Promise.resolve({ ok: false, error: { code: code, message: message } });
    } };
  }

  function installSidebarOpenExternalAdapter() {
    if (!isEmbeddedHost() || typeof window.fetch !== "function"
      || window[SIDEBAR_OPEN_EXTERNAL_ADAPTER_ATTR]) return;
    var nativeFetch = window.fetch;
    window[SIDEBAR_OPEN_EXTERNAL_ADAPTER_ATTR] = true;
    window.fetch = function (input, init) {
      var receiver = this;
      if (requestMethod(input, init) !== "POST"
        || !matchesOpenInAppPath(input, SIDEBAR_OPEN_EXTERNAL_PATH)) {
        return nativeFetch.call(receiver, input, init);
      }
      return requestBodyText(input, init).then(function (text) {
        var payload;
        try { payload = JSON.parse(text); } catch (_) {
          return sidebarOpenErrorResponse("bad-request", "打开请求不是有效的 JSON", 400);
        }
        if (!payload || payload.action !== "reveal") {
          return nativeFetch.call(receiver, input, init);
        }
        if (typeof payload.path !== "string" || payload.path === "") {
          return sidebarOpenErrorResponse("bad-request", "reveal 路径无效", 400);
        }
        return revealOpen(payload.path).then(sidebarOpenOkResponse).catch(function (error) {
          var message = (error && error.message) || "未知错误";
          warn("sidebar open-external failed for " + payload.path + ": " + message);
          return sidebarOpenErrorResponse("open_failed", message, 502);
        });
      });
    };
  }

  function installOpenInAppAdapter() {
    if (typeof window.fetch !== "function" || window[FETCH_ADAPTER_ATTR]) return;
    var nativeFetch = window.fetch;
    var embedded = isEmbeddedHost();
    window[FETCH_ADAPTER_ATTR] = true;
    window.fetch = function (input, init) {
      var receiver = this;
      var method = requestMethod(input, init);
      if (method === "GET" && matchesOpenInAppPath(input, OPEN_IN_APP_APPS_PATH)) {
        return Promise.resolve(fnosFileManagerAppsResponse(embedded));
      }
      if (method !== "POST" || !matchesOpenInAppPath(input, OPEN_IN_APP_OPEN_PATH)) {
        return nativeFetch.call(receiver, input, init);
      }
      return requestBodyText(input, init).then(function (text) {
        if (!embedded) {
          return openErrorResponse("unsupported_host", "独立浏览器页面不支持 fnOS 文件管理器", 400);
        }
        var payload;
        try { payload = JSON.parse(text); } catch (_) {
          return openErrorResponse("invalid_request", "打开请求不是有效的 JSON", 400);
        }
        if (!payload || payload.app !== FILE_MANAGER_APP_ID) {
          return openErrorResponse("unsupported_app", "fnOS iframe 仅支持文件管理器", 400);
        }
        if (typeof payload.path !== "string" || payload.path === "") {
          return openErrorResponse("invalid_path", "文件管理器路径无效", 400);
        }
        return openPath(payload.path, "openFileManager").then(successfulOpenResponse).catch(function (error) {
          var message = (error && error.message) || "未知错误";
          warn("file-manager open failed for " + payload.path + ": " + message);
          return openErrorResponse("open_failed", message, 502);
        });
      });
    };
  }

  primeSdk();
  installSessionExportAdapter();
  installSessionDownloadAnchorAdapter();
  installOpenInAppAdapter();
  installSidebarOpenExternalAdapter();
})();
