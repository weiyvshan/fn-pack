#!/usr/bin/env node
"use strict";

const net = require("net");

function selectLoopbackPort(callback) {
  const server = net.createServer();
  server.unref();
  server.once("error", callback);
  server.listen({ host: "127.0.0.1", port: 0, exclusive: true }, () => {
    const address = server.address();
    const port = address && typeof address === "object" ? address.port : 0;
    server.close((error) => callback(error || null, port));
  });
}

if (require.main === module) {
  selectLoopbackPort((error, port) => {
    if (error || !Number.isInteger(port) || port < 1 || port > 65535) {
      process.stderr.write(`unable to select loopback port: ${error ? error.message : "invalid result"}\n`);
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${port}\n`);
  });
}

module.exports = { selectLoopbackPort };
