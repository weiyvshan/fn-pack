#!/usr/bin/env node
"use strict";

const http = require("http");

function parsePort(value) {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`invalid loopback port: ${value}`);
  }
  return port;
}

function probeBackend(port, timeoutMs = 1000) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (ready) => {
      if (settled) return;
      settled = true;
      resolve(ready);
    };
    const request = http.get(
      { host: "127.0.0.1", port, path: "/", headers: { host: "127.0.0.1" }, agent: false },
      (response) => {
        response.resume();
        response.once("end", () => finish(true));
        response.once("error", () => finish(false));
      },
    );
    request.once("error", () => finish(false));
    request.setTimeout(timeoutMs, () => {
      request.destroy();
      finish(false);
    });
  });
}

if (require.main === module) {
  let port;
  try {
    port = parsePort(process.argv[2]);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
  const timeoutMs = Number(process.argv[3] || 1000);
  if (!Number.isInteger(timeoutMs) || timeoutMs < 50 || timeoutMs > 10000) {
    process.stderr.write(`invalid probe timeout: ${process.argv[3]}\n`);
    process.exit(2);
  }
  probeBackend(port, timeoutMs).then((ready) => {
    process.exitCode = ready ? 0 : 1;
  });
}

module.exports = { parsePort, probeBackend };
