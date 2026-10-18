#!/usr/bin/env node
"use strict";

const assert = require("assert/strict");
const fs = require("fs");
const http = require("http");
const net = require("net");
const os = require("os");
const path = require("path");
const vm = require("vm");
const { once, EventEmitter } = require("events");
const { startGatewayProxy, isAdaptedPluginClientPath } = require("../app/gateway-proxy.js");
const { assertKnownChangesSummaryClient } = require("../app/summary-client-compat.js");

const prefix = "/app/deepseek-harness";
const summaryPath = "/plugins/@deepseek-ai/dsh-client-ui-deliverables/client.js";
const combinedPath = "/plugins/??unrelated/client.js,@deepseek-ai/dsh-client-ui-deliverables/client.js&rev=fixture";
const fixture = fs.readFileSync(path.join(__dirname, "fixtures", "summary-client-bundle.js"), "utf8");

function deadline(promise) {
  let timer;
  const expired = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error("upstream close deadline exceeded")), 3000);
  });
  return Promise.race([promise, expired]).finally(() => clearTimeout(timer));
}

function get(socketPath, route, headers = {}) {
  return new Promise((resolve, reject) => {
    const request = http.get({
      socketPath, path: prefix + route,
      headers: { "x-trim-isadmin": "true", ...headers },
    }, response => {
      const chunks = [];
      response.on("data", chunk => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString() }));
      response.on("error", reject);
    });
    request.on("error", reject);
  });
}

function rawUpgrade(socketPath, { extra = Buffer.alloc(0), cancel = false } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath);
    const chunks = [];
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("raw upgrade test deadline exceeded"));
    }, 3000);
    socket.on("error", reject);
    socket.on("data", chunk => chunks.push(chunk));
    socket.on("close", () => {
      clearTimeout(timeout);
      resolve(Buffer.concat(chunks).toString());
    });
    socket.on("connect", () => {
      socket.write(`GET ${prefix}/api/remote.mux HTTP/1.1\r\nHost: fixture\r\nx-trim-isadmin: true\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: Zml4dHVyZWtleTEyMzQ1Ng==\r\n\r\n`);
      if (extra.length) socket.write(extra);
      if (cancel) Promise.resolve(cancel).then(() => socket.destroy(), reject);
    });
  });
}

(async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gateway-transport-"));
  const socketPath = path.join(root, "gateway.sock");
  const owned = new Set();
  let mode = "slow";
  let upstreamCloses = 0;
  const closeEvents = new EventEmitter();
  let conditionals = [];
  const backend = http.createServer((request, response) => {
    conditionals.push([request.headers["if-none-match"], request.headers["if-modified-since"]]);
    response.setHeader("content-type", "application/javascript; charset=utf-8");
    response.setHeader("etag", '"unmodified-bundle"');
    response.setHeader("last-modified", "Wed, 23 Sep 2026 00:00:00 GMT");
    response.setHeader("cache-control", "public, max-age=3600");
    response.end(fixture);
  });
  backend.on("upgrade", (_request, socket) => {
    owned.add(socket);
    socket.on("error", () => {});
    socket.once("end", () => socket.destroy());
    socket.resume();
    socket.once("close", () => {
      owned.delete(socket);
      upstreamCloses += 1;
      closeEvents.emit("close");
    });
    if (mode === "oversized-header") {
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nX-Fill: ${"x".repeat(65536)}\r\n\r\n`);
    }
    // Other cases intentionally never finish the handshake.
  });
  let gateway;
  try {
    backend.listen(0, "127.0.0.1");
    await once(backend, "listening");
    gateway = startGatewayProxy({
      socketPath, gatewayPrefix: prefix,
      target: { host: "127.0.0.1", port: backend.address().port },
      websocketHandshakeTimeoutMs: 100,
      websocketWriteStallTimeoutMs: 100,
    });
    await once(gateway, "listening");
    assert.equal(isAdaptedPluginClientPath(summaryPath), true);
    assert.equal(isAdaptedPluginClientPath(combinedPath), true);
    for (const route of [summaryPath, combinedPath]) {
      const response = await get(socketPath, route, {
        "if-none-match": '"unmodified-bundle"',
        "if-modified-since": "Wed, 23 Sep 2026 00:00:00 GMT",
      });
      assert.equal(response.status, 200);
      assert.equal(assertKnownChangesSummaryClient(response.body), "adapted");
      new vm.Script(response.body);
      assert.equal(response.headers["cache-control"], "no-store");
      assert.equal(response.headers.etag, undefined);
      assert.equal(response.headers["last-modified"], undefined);
      assert.deepEqual(conditionals.at(-1), [undefined, undefined]);
    }
    const unrelated = await get(socketPath, "/plugins/unrelated/client.js");
    assert.equal(assertKnownChangesSummaryClient(unrelated.body), "legacy", "matching code in unrelated resources is not adapted");
    const denied = await get(socketPath, summaryPath, { "x-trim-isadmin": "false" });
    assert.equal(denied.status, 403);

    const expiredClosed = once(closeEvents, "close");
    const slow = await rawUpgrade(socketPath);
    assert.match(slow, /^HTTP\/1\.1 502 Bad Gateway/);
    assert.match(slow, /handshake timed out/);
    await deadline(expiredClosed);
    assert.equal(upstreamCloses, 1, "expired handshakes release upstream sockets");
    mode = "oversized-header";
    const oversized = await rawUpgrade(socketPath);
    assert.match(oversized, /handshake header exceeded 64 KiB/);
    mode = "slow";
    const clientOverflow = await rawUpgrade(socketPath, { extra: Buffer.alloc(160 * 1024) });
    assert.match(clientOverflow, /pre-upgrade data exceeded 64 KiB/);
    const accepted = once(backend, "upgrade");
    const cancelled = rawUpgrade(socketPath, { cancel: accepted });
    const [, pendingSocket] = await deadline(accepted);
    const cancelledClosed = once(pendingSocket, "close");
    await cancelled;
    await deadline(cancelledClosed);
    assert.equal(pendingSocket.destroyed, true, "client cancellation releases the pending upstream handshake");
    process.stdout.write("gateway-transport tests passed\n");
  } finally {
    for (const socket of owned) socket.destroy();
    if (gateway) await new Promise(resolve => gateway.close(resolve));
    await new Promise(resolve => backend.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
