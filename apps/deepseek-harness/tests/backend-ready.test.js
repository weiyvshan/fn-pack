#!/usr/bin/env node
"use strict";

const assert = require("assert/strict");
const http = require("http");
const { parsePort, probeBackend } = require("../app/backend-ready.js");

assert.equal(parsePort("1234"), 1234);
assert.throws(() => parsePort("0"));
assert.throws(() => parsePort("65536"));

const server = http.createServer((_request, response) => {
  response.writeHead(200);
  response.end("ready");
});

server.listen(0, "127.0.0.1", async () => {
  const address = server.address();
  const port = address.port;
  try {
    assert.equal(await probeBackend(port, 500), true);
    assert.equal(await probeBackend(port + 1, 50), false);
    process.stdout.write("backend-ready tests passed\n");
  } finally {
    server.close();
  }
});
