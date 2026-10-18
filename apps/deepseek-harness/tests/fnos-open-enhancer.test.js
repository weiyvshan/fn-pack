"use strict";

const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

class FakeEventTarget {
  constructor() {
    this.listeners = new Map();
  }

  addEventListener(type, listener, capture = false) {
    const entries = this.listeners.get(type) || [];
    entries.push({ listener, capture });
    this.listeners.set(type, entries);
  }

  dispatchEvent(event) {
    const entries = this.listeners.get(event.type) || [];
    for (const entry of entries.filter((item) => item.capture)) {
      entry.listener.call(this, event);
      if (event.immediateStopped) return !event.defaultPrevented;
    }
    if (event.propagationStopped) return !event.defaultPrevented;
    for (const entry of entries.filter((item) => !item.capture)) {
      entry.listener.call(this, event);
      if (event.immediateStopped) return !event.defaultPrevented;
    }
    return !event.defaultPrevented;
  }
}

class FakeElement extends FakeEventTarget {
  constructor(tagName) {
    super();
    this.tagName = tagName.toUpperCase();
    this.attributes = new Map();
    this.children = [];
    this.parentElement = null;
    this.textContent = "";
    this.disabled = false;
    this.type = "";
    this.title = "";
    this.href = "";
    this.download = "";
  }

  click() {}

  appendChild(child) {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  matches(selector) {
    const tag = selector.match(/^([a-z]+)/i);
    if (tag && this.tagName !== tag[1].toUpperCase()) return false;
    const attribute = selector.match(/\[([^\]=^]+)(\^)?(?:="([^"]*)")?\]/);
    if (!attribute) return true;
    const value = this.getAttribute(attribute[1]);
    if (value === null) return false;
    return attribute[2] ? value.startsWith(attribute[3]) : !attribute[3] || value === attribute[3];
  }

  querySelectorAll(selector) {
    const matches = [];
    const visit = (element) => {
      for (const child of element.children) {
        if (child.matches(selector)) matches.push(child);
        visit(child);
      }
    };
    visit(this);
    return matches;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  previousElementSibling() {
    if (!this.parentElement) return null;
    const index = this.parentElement.children.indexOf(this);
    return index > 0 ? this.parentElement.children[index - 1] : null;
  }
}

Object.defineProperty(FakeElement.prototype, "previousElementSibling", {
  get() {
    if (!this.parentElement) return null;
    const index = this.parentElement.children.indexOf(this);
    return index > 0 ? this.parentElement.children[index - 1] : null;
  },
});

function makeCard(filePath) {
  const card = new FakeElement("div");
  card.setAttribute("data-presented-file", "true");

  const preview = new FakeElement("button");
  preview.setAttribute("title", filePath);
  preview.setAttribute("aria-label", `在侧边栏预览 ${filePath}`);
  card.appendChild(preview);

  const body = new FakeElement("div");
  const split = new FakeElement("div");
  const open = new FakeElement("button");
  open.setAttribute("aria-label", `在侧边栏打开 ${filePath}`);
  open.textContent = "打开";
  const menuAnchor = new FakeElement("span");
  const chevron = new FakeElement("button");
  chevron.setAttribute("aria-haspopup", "menu");
  chevron.disabled = true;
  menuAnchor.appendChild(chevron);
  split.appendChild(open);
  split.appendChild(menuAnchor);
  body.appendChild(split);
  card.appendChild(body);

  return { card, open };
}

function makeHarness(
  filePaths,
  {
    embedded = true,
    sdkReady = "resolved",
    sdkReadyTimeoutMs = 50,
    userAgent = "Mozilla/5.0 FNOS/1.2.8 FNAppType/Web FNAppVer/1.0.0",
    visibleRoots = ["/vol1/share"],
    statIsDir = () => false,
  } = {},
) {
  const body = new FakeElement("body");
  const head = new FakeElement("head");
  for (const filePath of filePaths) body.appendChild(makeCard(filePath).card);

  const document = new FakeEventTarget();
  document.readyState = "complete";
  document.body = body;
  document.head = head;
  document.createElement = (tagName) => new FakeElement(tagName);
  document.querySelectorAll = (selector) => body.querySelectorAll(selector);

  const openCalls = [];
  const fileManagerCalls = [];
  const fetchCalls = [];
  const sdkConstructionUserAgents = [];
  const navigator = { userAgent };
  let bootstrapComplete = false;
  class MockTrimApp {
    constructor() {
      sdkConstructionUserAgents.push(navigator.userAgent);
      this.constructedDuringBootstrap = !bootstrapComplete;
      this.isWeb = !/\bFNAppVer\//i.test(navigator.userAgent);
      this.isStandaloneWeb = false;
    }

    ready() {
      if (sdkReady === "pending"
        || (sdkReady === "early-only" && !this.constructedDuringBootstrap)) {
        return new Promise(() => {});
      }
      return Promise.resolve();
    }

    openFile(filePath) {
      openCalls.push(filePath);
      return Promise.resolve();
    }

    openFileManager(filePath) {
      fileManagerCalls.push(filePath);
      return Promise.resolve();
    }
  }

  const nativeFetch = async (url, options) => {
    fetchCalls.push({ url, options });
    const value = typeof url === "string" ? url : url.url;
    const pathname = new URL(value, "https://nas.test/app/deepseek-harness/").pathname;
    if (pathname.endsWith("/open-in-app/apps")) {
      return Response.json({ apps: ["vscode"] });
    }
    if (pathname.endsWith("/__fnos/stat")) {
      const statBody = JSON.parse(options.body);
      return Response.json({ isDir: !!statIsDir(statBody.path) });
    }
    if (pathname.endsWith("/__fnos/export-open")) {
      return Response.json({ path: "/vol1/share/dsh-exports/exported.md" });
    }
    if (pathname.endsWith("/__fnos/export-session")) {
      return Response.json({ path: "/vol1/share/dsh-exports/dsh-session-session-123.zip" });
    }
    return new Response(null, { status: 204 });
  };
  const sandbox = {
    document,
    Headers,
    navigator,
    Promise,
    Request,
    Response,
    URL,
    console,
    location: {
      href: "https://nas.test/app/deepseek-harness/",
      origin: "https://nas.test",
    },
    setTimeout,
    clearTimeout,
    fetch: nativeFetch,
    MutationObserver: class {
      observe() {}
    },
    __DSH_FNOS__: {
      prefix: "/app/deepseek-harness",
      visibleRoots,
      sdkPath: "/app/deepseek-harness/__fnos/trim-web-app.js",
      exportPath: "/app/deepseek-harness/__fnos/export-open",
      statPath: "/app/deepseek-harness/__fnos/stat",
      sessionExportPath: "/app/deepseek-harness/__fnos/export-session",
      sdkReadyTimeoutMs,
    },
    TrimAppSDK: { TrimApp: MockTrimApp },
  };
  sandbox.window = sandbox;
  sandbox.parent = embedded ? {} : sandbox;
  sandbox.requestAnimationFrame = (callback) => callback();

  const source = fs.readFileSync(
    path.join(__dirname, "..", "app", "web", "fnos-open-enhancer.js"),
    "utf8",
  );
  vm.runInNewContext(source, sandbox, { filename: "fnos-open-enhancer.js" });
  bootstrapComplete = true;

  return {
    body,
    fetch: (input, init) => sandbox.fetch(input, init),
    fileManagerCalls,
    openCalls,
    fetchCalls,
    document,
    navigator,
    sdkConstructionUserAgents,
    cards: body.querySelectorAll("div[data-presented-file]"),
  };
}

function click(element) {
  let defaultPrevented = false;
  let propagationStopped = false;
  let immediateStopped = false;
  const event = {
    type: "click",
    preventDefault: () => { defaultPrevented = true; },
    stopPropagation: () => { propagationStopped = true; },
    stopImmediatePropagation: () => { immediateStopped = true; propagationStopped = true; },
    get defaultPrevented() { return defaultPrevented; },
    get propagationStopped() { return propagationStopped; },
    get immediateStopped() { return immediateStopped; },
  };
  element.dispatchEvent(event);
  return event;
}

async function flushPromises() {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
}

function probeVendoredSdk(userAgent) {
  const parent = { postMessage() {} };
  const window = {
    parent,
    addEventListener() {},
    removeEventListener() {},
    postMessage() {},
    setTimeout() { return 1; },
    clearTimeout() {},
  };
  const context = {
    window,
    navigator: { userAgent },
    console,
    Promise,
    Map,
    Error,
    JSON,
    URL,
    Symbol,
    Object,
    Array,
    String,
    Number,
    Boolean,
    RegExp,
    Math,
    Date,
    setTimeout: window.setTimeout,
    clearTimeout: window.clearTimeout,
  };
  const source = fs.readFileSync(
    path.join(__dirname, "..", "app", "web", "trim-web-app-0.4.2.iife.js"),
    "utf8",
  );
  vm.runInNewContext(source, context, { filename: "trim-web-app-0.4.2.iife.js" });
  const sdk = new context.TrimAppSDK.TrimApp();
  return { isWeb: sdk.isWeb, isStandaloneWeb: sdk.isStandaloneWeb };
}

async function main() {
  assert.deepEqual(
    probeVendoredSdk("Mozilla/5.0 FNOS/1.2.8 FNAppType/Web FNAppVer/1.0.0"),
    { isWeb: false, isStandaloneWeb: false },
  );
  assert.deepEqual(
    probeVendoredSdk("Mozilla/5.0 FNOS/1.2.8 FNAppType/Web"),
    { isWeb: true, isStandaloneWeb: false },
  );

  const sharedPath = "/vol1/share/report.md";
  const privatePath = "/var/lib/deepseek-harness/.dsh/exported.md";
  const harness = makeHarness([sharedPath, privatePath]);
  const sidebarButtons = harness.cards.map((card) => card
    .querySelectorAll("button")
    .find((button) => button.textContent === "打开"));
  let sidebarClicks = 0;
  for (const button of sidebarButtons) button.addEventListener("click", () => { sidebarClicks += 1; });

  assert.equal(sidebarButtons[0].getAttribute("data-dsh-fnos-open"), null);
  assert.equal(sidebarButtons[0].getAttribute("aria-label"), `在侧边栏打开 ${sharedPath}`);

  const sharedEvent = click(sidebarButtons[0]);
  await flushPromises();
  assert.equal(sharedEvent.defaultPrevented, false);
  assert.equal(sharedEvent.propagationStopped, false);
  assert.equal(sidebarClicks, 1);
  assert.deepEqual(harness.openCalls, []);
  assert.equal(harness.fetchCalls.length, 0);
  assert.deepEqual(harness.sdkConstructionUserAgents, [
    "Mozilla/5.0 FNOS/1.2.8 FNAppType/Web",
  ]);
  assert.match(harness.navigator.userAgent, /\bFNAppVer\//);

  const privateEvent = click(sidebarButtons[1]);
  await flushPromises();
  assert.equal(privateEvent.defaultPrevented, false);
  assert.equal(privateEvent.propagationStopped, false);
  assert.equal(sidebarClicks, 2);
  assert.equal(harness.fetchCalls.length, 0);
  assert.deepEqual(harness.openCalls, []);

  const apps = await (await harness.fetch("/open-in-app/apps")).json();
  assert.deepEqual(apps, { apps: ["filemanager"] });
  assert.equal(
    harness.fetchCalls.filter((call) => String(call.url).endsWith("/open-in-app/apps")).length,
    0,
  );

  const sharedWorkspace = "/vol1/share/projects/demo";
  const fileManagerResponse = await harness.fetch("/open-in-app/open", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ app: "filemanager", path: sharedWorkspace }),
  });
  assert.equal(fileManagerResponse.status, 204);
  assert.deepEqual(harness.fileManagerCalls, [sharedWorkspace]);
  assert.equal(
    harness.fetchCalls.filter((call) => String(call.url).endsWith("/open-in-app/open")).length,
    0,
  );

  const noteWorkspace = "/vol1/1000/Note";
  const earlyHarness = makeHarness([], {
    sdkReady: "early-only",
    visibleRoots: [noteWorkspace],
  });
  assert.deepEqual(earlyHarness.sdkConstructionUserAgents, [
    "Mozilla/5.0 FNOS/1.2.8 FNAppType/Web",
  ]);
  const noteResponse = await earlyHarness.fetch("/open-in-app/open", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ app: "filemanager", path: noteWorkspace }),
  });
  assert.equal(noteResponse.status, 204);
  assert.deepEqual(earlyHarness.fileManagerCalls, [noteWorkspace]);
  assert.equal(
    earlyHarness.fetchCalls.filter((call) => String(call.url).endsWith("/__fnos/export-open")).length,
    0,
  );

  const editorPath = "/vol1/share/projects/demo";
  const editorResponse = await harness.fetch("/open-in-app/open", {
    method: "POST",
    body: JSON.stringify({ app: "zed", path: editorPath }),
  });
  assert.equal(editorResponse.status, 400);
  assert.deepEqual(await editorResponse.json(), {
    error: "unsupported_app",
    message: "fnOS iframe 仅支持文件管理器",
  });
  assert.equal(
    harness.fetchCalls.filter((call) => String(call.url).endsWith("/open-in-app/open")).length,
    0,
  );
  assert.deepEqual(harness.fileManagerCalls, [sharedWorkspace]);

  await harness.fetch("https://external.test/open-in-app/open", {
    method: "POST",
    body: JSON.stringify({ app: "filemanager", path: sharedWorkspace }),
  });
  assert.equal(
    harness.fetchCalls.filter((call) => String(call.url).includes("external.test/open-in-app/open")).length,
    1,
  );
  assert.deepEqual(harness.fileManagerCalls, [sharedWorkspace]);

  const privateWorkspaceFile = "/var/lib/deepseek-harness/.dsh/session.md";
  await harness.fetch("/open-in-app/open", {
    method: "POST",
    body: JSON.stringify({ app: "filemanager", path: privateWorkspaceFile }),
  });
  assert.deepEqual(
    JSON.parse(harness.fetchCalls.at(-1).options.body),
    { path: privateWorkspaceFile },
  );
  assert.deepEqual(harness.fileManagerCalls, [
    sharedWorkspace,
    "/vol1/share/dsh-exports",
  ]);

  const sessionProbe = await harness.fetch(
    "/api/session.export?sessionId=session-123&includeDescendants=true",
    { method: "HEAD" },
  );
  assert.equal(sessionProbe.status, 204);
  const sessionExportCall = harness.fetchCalls.at(-1);
  assert.equal(sessionExportCall.url, "/app/deepseek-harness/__fnos/export-session");
  assert.deepEqual(JSON.parse(sessionExportCall.options.body), {
    sessionId: "session-123",
    includeDescendants: true,
  });
  const sessionAnchor = harness.document.createElement("a");
  sessionAnchor.href = "https://nas.test/api/session.export?sessionId=session-123&includeDescendants=true";
  sessionAnchor.download = "dsh-session-session-123.zip";
  sessionAnchor.click();
  await flushPromises();
  assert.deepEqual(harness.fileManagerCalls, [
    sharedWorkspace,
    "/vol1/share/dsh-exports",
    "/vol1/share/dsh-exports",
  ]);

  const fallbackAnchor = harness.document.createElement("a");
  fallbackAnchor.href = "https://nas.test/api/session.export?sessionId=session-456";
  fallbackAnchor.download = "dsh-session-session-456.zip";
  fallbackAnchor.click();
  await flushPromises();
  assert.equal(
    harness.fetchCalls.filter((call) => call.url === "/app/deepseek-harness/__fnos/export-session").length,
    2,
  );
  assert.deepEqual(harness.fileManagerCalls, [
    sharedWorkspace,
    "/vol1/share/dsh-exports",
    "/vol1/share/dsh-exports",
    "/vol1/share/dsh-exports",
  ]);

  const standalone = makeHarness([], { embedded: false });
  const standaloneApps = await (await standalone.fetch("/open-in-app/apps")).json();
  assert.deepEqual(standaloneApps, { apps: [] });
  const standaloneOpen = await standalone.fetch("/open-in-app/open", {
    method: "POST",
    body: JSON.stringify({ app: "filemanager", path: sharedWorkspace }),
  });
  assert.equal(standaloneOpen.status, 400);
  assert.deepEqual(await standaloneOpen.json(), {
    error: "unsupported_host",
    message: "独立浏览器页面不支持 fnOS 文件管理器",
  });
  assert.deepEqual(standalone.fileManagerCalls, []);
  assert.equal(
    standalone.fetchCalls.filter((call) => String(call.url).endsWith("/open-in-app/open")).length,
    0,
  );

  // dsh-better-sidebar 文件树右键「在应用中打开」走 POST /sidebar/api/open.external，
  // 服务端在 Linux 上交给 xdg-open（fnOS 不存在，错误被吞）。fnOS 嵌入环境下由
  // 适配器接管 reveal 动作并转发到 fnOS 文件管理器；独立浏览器页与 url 动作保持透传。
  const sidebarHarness = makeHarness([]);
  const sidebarSharedFile = "/vol1/share/projects/demo/report.md";
  const sidebarReveal = await sidebarHarness.fetch("/sidebar/api/open.external", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "reveal", path: sidebarSharedFile }),
  });
  assert.equal(sidebarReveal.status, 200);
  assert.deepEqual(await sidebarReveal.json(), { ok: true, value: { started: true } });
  assert.deepEqual(sidebarHarness.fileManagerCalls, ["/vol1/share/projects/demo"]);
  assert.equal(
    sidebarHarness.fetchCalls.filter((call) => String(call.url).endsWith("/sidebar/api/open.external")).length,
    0,
  );

  const sidebarPrivateFile = "/var/lib/deepseek-harness/.dsh/notes.md";
  const sidebarPrivate = await sidebarHarness.fetch("/sidebar/api/open.external", {
    method: "POST",
    body: JSON.stringify({ action: "reveal", path: sidebarPrivateFile }),
  });
  assert.equal(sidebarPrivate.status, 200);
  assert.deepEqual(await sidebarPrivate.json(), { ok: true, value: { started: true } });
  assert.deepEqual(
    JSON.parse(sidebarHarness.fetchCalls.at(-1).options.body),
    { path: sidebarPrivateFile },
  );
  assert.deepEqual(sidebarHarness.fileManagerCalls, [
    "/vol1/share/projects/demo",
    "/vol1/share/dsh-exports",
  ]);

  await sidebarHarness.fetch("/sidebar/api/open.external", {
    method: "POST",
    body: JSON.stringify({ action: "url", url: "vscode://file/vol1/share/demo.md" }),
  });
  assert.equal(
    sidebarHarness.fetchCalls.filter((call) => String(call.url).endsWith("/sidebar/api/open.external")).length,
    1,
  );
  assert.equal(sidebarHarness.fileManagerCalls.length, 2);

  // 方案 B：目录 reveal 打开目录自身。
  const sidebarDir = "/vol1/share/projects";
  const dirHarness = makeHarness([], { statIsDir: (p) => p === sidebarDir });
  const dirReveal = await dirHarness.fetch("/sidebar/api/open.external", {
    method: "POST",
    body: JSON.stringify({ action: "reveal", path: sidebarDir }),
  });
  assert.equal(dirReveal.status, 200);
  assert.deepEqual(dirHarness.fileManagerCalls, [sidebarDir]);

  // 探测失败（stat 抛错）按文件回退父目录。
  const probeFailHarness = makeHarness([], {
    statIsDir: () => { throw new Error("probe down"); },
  });
  const probeFailReveal = await probeFailHarness.fetch("/sidebar/api/open.external", {
    method: "POST",
    body: JSON.stringify({ action: "reveal", path: sidebarSharedFile }),
  });
  assert.equal(probeFailReveal.status, 200);
  assert.deepEqual(probeFailHarness.fileManagerCalls, ["/vol1/share/projects/demo"]);

  const sidebarOther = await sidebarHarness.fetch("/sidebar/api/fs.tree", {
    method: "POST",
    body: JSON.stringify({ sessionId: "session-123", path: "/vol1/share" }),
  });
  assert.equal(sidebarOther.status, 204);
  assert.equal(
    sidebarHarness.fetchCalls.filter((call) => String(call.url).endsWith("/sidebar/api/fs.tree")).length,
    1,
  );

  const sidebarBadPath = await sidebarHarness.fetch("/sidebar/api/open.external", {
    method: "POST",
    body: JSON.stringify({ action: "reveal", path: "" }),
  });
  assert.equal(sidebarBadPath.status, 400);
  assert.deepEqual(await sidebarBadPath.json(), {
    ok: false,
    error: { code: "bad-request", message: "reveal 路径无效" },
  });

  const sidebarStandalone = makeHarness([], { embedded: false });
  await sidebarStandalone.fetch("/sidebar/api/open.external", {
    method: "POST",
    body: JSON.stringify({ action: "reveal", path: "/vol1/share/demo.md" }),
  });
  assert.equal(
    sidebarStandalone.fetchCalls.filter((call) => String(call.url).endsWith("/sidebar/api/open.external")).length,
    1,
  );
  assert.deepEqual(sidebarStandalone.fileManagerCalls, []);

  const timeoutHarness = makeHarness([], { sdkReady: "pending", sdkReadyTimeoutMs: 10 });
  const timeoutResponse = await timeoutHarness.fetch("/open-in-app/open", {
    method: "POST",
    body: JSON.stringify({ app: "filemanager", path: sharedWorkspace }),
  });
  assert.equal(timeoutResponse.status, 502);
  const timeoutPayload = await timeoutResponse.json();
  assert.equal(timeoutPayload.error, "open_failed");
  assert.match(timeoutPayload.message, /10ms/);
  assert.deepEqual(timeoutHarness.fileManagerCalls, []);

  console.log("fnos-open-enhancer tests passed");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
