#!/usr/bin/env node
"use strict";

const assert = require("assert/strict");
const { once } = require("events");
const net = require("net");
const { PassThrough, Duplex } = require("stream");
const { relayWebSocket, validateTimeout } = require("../app/gateway-websocket.js");

async function socketPair() {
  const server = net.createServer({ allowHalfOpen: true });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const accepted = once(server, "connection");
  const outgoing = net.connect(server.address().port, "127.0.0.1");
  await once(outgoing, "connect");
  const [incoming] = await accepted;
  return {
    outgoing,
    incoming,
    close: async () => {
      outgoing.destroy();
      incoming.destroy();
      await new Promise(resolve => server.close(resolve));
    },
  };
}

function receive(socket, size) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    const timer = setTimeout(() => finish(new Error("receive deadline exceeded")), 5000);
    const finish = (error) => {
      clearTimeout(timer);
      socket.off("data", data);
      socket.off("close", closed);
      if (error) reject(error);
      else resolve(Buffer.concat(chunks, bytes));
    };
    const closed = () => finish(new Error(`closed after ${bytes} of ${size} bytes`));
    const data = (chunk) => {
      chunks.push(chunk);
      bytes += chunk.length;
      if (bytes >= size) finish();
    };
    socket.on("data", data);
    socket.once("close", closed);
  });
}

async function testLargeRelay() {
  const client = await socketPair();
  const backend = await socketPair();
  try {
    const serverHead = Buffer.from("HTTP/1.1 101 Switching Protocols\r\n\r\n");
    const clientHead = Buffer.from([0x81, 0x80, 1, 2, 3, 4]);
    const payload = Buffer.from(JSON.stringify({ snapshot: "\u6c49".repeat(2700000) }));
    const frameHeader = Buffer.alloc(10);
    frameHeader[0] = 0x81;
    frameHeader[1] = 127;
    frameHeader.writeBigUInt64BE(BigInt(payload.length), 2);
    const frame = Buffer.concat([frameHeader, payload]);
    const expected = Buffer.concat([serverHead, frame]);
    const downstream = receive(client.outgoing, expected.length);
    const firstFrame = receive(backend.incoming, clientHead.length);
    const finish = relayWebSocket(client.incoming, backend.outgoing, {
      serverHead, clientHead, writeStallTimeoutMs: 1000,
    });
    let upstreamBytes = 0;
    backend.incoming.on("data", chunk => { upstreamBytes += chunk.length; });
    backend.incoming.write(frame);
    assert.deepEqual(await downstream, expected, "an 8 MiB UTF-8 frame and upgrade head pass unchanged");
    assert.deepEqual(await firstFrame, clientHead);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(upstreamBytes, clientHead.length, "the coalesced first client frame is not duplicated");
    const backendClosed = once(backend.outgoing, "close");
    client.outgoing.destroy();
    await backendClosed;
    assert.equal(backend.outgoing.destroyed, true, "client close tears down the upstream socket");
    finish();
    finish();
  } finally {
    await client.close();
    await backend.close();
  }
}

async function testWriteStalls(direction) {
  // A stopped destination gives deterministic stream backpressure in either direction.
  const client = new PassThrough({ highWaterMark: 1024 });
  const upstream = new PassThrough({ highWaterMark: 1024 });
  const stalled = direction === "downstream" ? client : upstream;
  const source = direction === "downstream" ? upstream : client;
  let report;
  const closed = once(stalled, "close");
  const finish = relayWebSocket(client, upstream, {
    writeStallTimeoutMs: 25,
    onStall: value => { report = value; throw new Error("diagnostic callback failed"); },
  });
  const keepAlive = setTimeout(finish, 2000);
  try {
    // Pause after relay installation; resume only the producing side.
    stalled.pause();
    source.write(Buffer.alloc(8192));
    source.resume();
    await closed;
    assert.equal(client.destroyed, true);
    assert.equal(upstream.destroyed, true);
    assert.equal(report.direction, direction);
    assert.ok(report.bufferedBytes > 0);
    assert.equal(client.listenerCount("drain"), 0);
    assert.equal(upstream.listenerCount("drain"), 0);
    finish();
  } finally {
    clearTimeout(keepAlive);
    client.destroy();
    upstream.destroy();
  }
}

async function testEofFlush() {
  const writes = [];
  const client = new Duplex({
    allowHalfOpen: true,
    read() {},
    write(chunk, _encoding, callback) {
      setTimeout(() => {
        if (!this.destroyed) writes.push(Buffer.from(chunk));
        callback();
      }, 40);
    },
  });
  const upstream = new Duplex({
    allowHalfOpen: true,
    read() {},
    write(_chunk, _encoding, callback) { callback(); },
  });
  const closed = once(client, "close");
  const finish = relayWebSocket(client, upstream, { writeStallTimeoutMs: 500 });
  upstream.push(Buffer.from("final frame"));
  upstream.push(null);
  await closed;
  assert.equal(Buffer.concat(writes).toString(), "final frame", "EOF flushes queued bytes before tearing down the relay");
  finish();
}

async function testProgressingWrites() {
  const writes = [];
  let stalled = false;
  const client = new Duplex({
    allowHalfOpen: true,
    highWaterMark: 1,
    read() {},
    write(chunk, _encoding, callback) {
      setTimeout(() => {
        if (!this.destroyed) writes.push(Buffer.from(chunk));
        callback();
      }, 30);
    },
  });
  const upstream = new Duplex({
    allowHalfOpen: true,
    read() {},
    write(_chunk, _encoding, callback) { callback(); },
  });
  const closed = once(client, "close");
  const finish = relayWebSocket(client, upstream, { writeStallTimeoutMs: 50, onStall: () => { stalled = true; } });
  upstream.push(Buffer.from("one"));
  upstream.push(Buffer.from("two"));
  upstream.push(Buffer.from("three"));
  upstream.push(null);
  await closed;
  assert.equal(Buffer.concat(writes).toString(), "onetwothree", "drains permit a progressing transfer longer than one stall interval");
  assert.equal(stalled, false);
  finish();
}

async function testEofDrainDeadline() {
  const client = new Duplex({ allowHalfOpen: true, read() {}, write(_chunk, _encoding, _callback) {} });
  const upstream = new Duplex({ allowHalfOpen: true, read() {}, write(_chunk, _encoding, callback) { callback(); } });
  const closed = once(client, "close");
  const finish = relayWebSocket(client, upstream, { writeStallTimeoutMs: 25 });
  const started = Date.now();
  const fallback = setTimeout(finish, 2000);
  upstream.push(Buffer.from("tail"));
  upstream.push(null);
  try {
    await closed;
    assert.ok(Date.now() - started < 1000, "EOF drain is bounded even below the high-water mark");
    assert.equal(upstream.destroyed, true);
  } finally {
    clearTimeout(fallback);
    finish();
  }
}

(async () => {
  assert.equal(validateTimeout(1, "test"), 1);
  assert.equal(validateTimeout(2147483647, "test"), 2147483647);
  for (const value of [0, -1, 1.5, Infinity, 2147483648, "1000"]) {
    assert.throws(() => validateTimeout(value, "test"), RangeError);
  }
  await testLargeRelay();
  await testWriteStalls("downstream");
  await testWriteStalls("upstream");
  await testEofFlush();
  await testProgressingWrites();
  await testEofDrainDeadline();
  process.stdout.write("gateway-websocket tests passed\n");
})().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
