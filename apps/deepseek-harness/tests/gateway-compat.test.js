#!/usr/bin/env node
"use strict";

const assert = require("assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  deletePlugin,
  emptyRegistry,
  normalizeRoot,
  packageDirectory,
  readRegistry,
  rootsForProfile,
  scanPluginRoots,
  scanTextRoots,
  setPlugin,
  writeRegistry,
} = require("../app/gateway-compat.js");

assert.equal(normalizeRoot("/sidebar/"), "/sidebar/");
assert.equal(normalizeRoot("/API/"), null);
assert.equal(normalizeRoot("/api/"), null);
assert.equal(normalizeRoot("/a/"), null);
assert.deepEqual(scanTextRoots('fetch("/sidebar/api/fs.list"); new WebSocket("/other/ws");'), ["/other/", "/sidebar/"]);
assert.deepEqual(scanTextRoots('"https://example.test/sidebar/api" "/sidebars/api"'), ["/sidebars/"]);

const root = fs.mkdtempSync(path.join(os.tmpdir(), "gateway-compat-test-"));
try {
  const packageDir = path.join(root, "package");
  fs.mkdirSync(path.join(packageDir, "lib"), { recursive: true });
  fs.writeFileSync(path.join(packageDir, "lib", "client.js"), 'fetch(`/sidebar/api/list`); fetch("/api/native");');
  assert.deepEqual(scanPluginRoots(packageDir), ["/sidebar/"]);

  const profilePackageRoot = path.join(root, "profile");
  const insidePackage = path.join(profilePackageRoot, "node_modules", ".store", "inside");
  const outsidePackage = path.join(root, "outside-package");
  fs.mkdirSync(insidePackage, { recursive: true });
  fs.mkdirSync(outsidePackage, { recursive: true });
  const directoryLinkType = process.platform === "win32" ? "junction" : "dir";
  fs.symlinkSync(insidePackage, path.join(profilePackageRoot, "node_modules", "inside"), directoryLinkType);
  fs.symlinkSync(outsidePackage, path.join(profilePackageRoot, "node_modules", "outside"), directoryLinkType);
  assert.equal(packageDirectory(profilePackageRoot, "inside"), fs.realpathSync(insidePackage));
  assert.equal(packageDirectory(profilePackageRoot, "outside"), null);

  const registryPath = path.join(root, "gateway-compat.json");
  let registry = setPlugin(emptyRegistry(), "web", "dsh-better-sidebar", "0.12.2", ["/sidebar/"], "known");
  writeRegistry(registryPath, registry);
  registry = readRegistry(registryPath, { strict: true });
  assert.deepEqual(rootsForProfile(registry, "web"), ["/sidebar/"]);
  registry = deletePlugin(registry, "web", "dsh-better-sidebar");
  assert.deepEqual(rootsForProfile(registry, "web"), []);

} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

process.stdout.write("gateway-compat tests passed\n");
