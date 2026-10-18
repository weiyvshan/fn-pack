"use strict";

const MAX_TIMER_MS = 2147483647;

function validateTimeout(value, name) {
  if (!Number.isSafeInteger(value) || value < 1 || value > MAX_TIMER_MS) {
    throw new RangeError(`${name} must be an integer from 1 through ${MAX_TIMER_MS}`);
  }
  return value;
}

/** Relay unchanged upgrade bytes, owning both sockets until close or a bounded local write stall. */
function relayWebSocket(client, upstream, {
  serverHead = Buffer.alloc(0),
  clientHead = Buffer.alloc(0),
  writeStallTimeoutMs = 45000,
  onStall = () => {},
} = {}) {
  validateTimeout(writeStallTimeoutMs, "WebSocket write stall timeout");
  let closed = false;
  let ending = false;
  let finalDrainTimer;
  const cleanups = [];

  const finish = () => {
    if (closed) return;
    closed = true;
    clearTimeout(finalDrainTimer);
    for (const cleanup of cleanups) cleanup();
    client.unpipe(upstream);
    upstream.unpipe(client);
    upstream.destroy();
    client.destroy();
  };
  const onEnd = () => {
    if (closed || ending) return;
    ending = true;
    client.unpipe(upstream);
    upstream.unpipe(client);
    // end() drains already queued bytes; destroy() would drop an unwritten tail frame.
    finalDrainTimer = setTimeout(finish, writeStallTimeoutMs);
    finalDrainTimer.unref();
    let pending = 2;
    const drained = () => { if (--pending === 0) finish(); };
    client.end(drained);
    upstream.end(drained);
  };
  const onClose = () => { if (!ending) finish(); };
  for (const socket of [client, upstream]) {
    socket.once("close", onClose);
    socket.once("end", onEnd);
    socket.once("error", finish);
    cleanups.push(() => {
      socket.off("close", onClose);
      socket.off("end", onEnd);
      // Keep an error sink while destroy() settles; close tears down the peer.
      socket.off("error", finish);
      socket.once("error", () => {});
    });
  }

  const watch = (source, destination, direction) => {
    let timer;
    const clear = () => {
      clearTimeout(timer);
      timer = undefined;
    };
    const inspect = () => {
      if (closed || !destination.writableNeedDrain || timer !== undefined) return;
      timer = setTimeout(() => {
        timer = undefined;
        if (closed || !destination.writableNeedDrain) return;
        const bufferedBytes = destination.writableLength;
        finish();
        try { onStall({ direction, bufferedBytes }); } catch (_) {
          // Diagnostics never own the relay's socket lifetime.
        }
      }, writeStallTimeoutMs);
      timer.unref();
    };
    destination.on("drain", clear);
    // pipe() installs its write listener first, so this observes that write's backpressure.
    source.on("data", inspect);
    cleanups.push(() => {
      clear();
      destination.off("drain", clear);
      source.off("data", inspect);
    });
    inspect();
  };

  if (client.destroyed || upstream.destroyed) {
    finish();
    return finish;
  }
  if (serverHead.length) client.write(serverHead);
  if (clientHead.length) upstream.write(clientHead);
  client.pipe(upstream);
  upstream.pipe(client);
  watch(upstream, client, "downstream");
  watch(client, upstream, "upstream");
  return finish;
}

module.exports = { relayWebSocket, validateTimeout };
