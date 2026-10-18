#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const REGISTRY_VERSION = 1;
const MAX_PLUGIN_FILES = 256;
const MAX_SCAN_FILE_BYTES = 4 * 1024 * 1024;
const MAX_SCAN_BYTES = 16 * 1024 * 1024;
const ROOT_PATTERN = /^\/[a-z][a-z0-9._-]{1,63}\/$/;
const ROOT_IN_TEXT = /(?:^|["'`(= ])(\/[a-z][a-z0-9._-]{1,63}\/)/g;
const RESERVED_ROOTS = new Set([
  "/app/",
  "/api/",
  "/assets/",
  "/plugins/",
  "/cgi/",
  "/webman/",
  "/__fnos/",
]);

const KNOWN_PLUGIN_ROOTS = Object.freeze({
  "dsh-better-sidebar": Object.freeze(["/sidebar/"]),
});

function emptyRegistry() {
  return { version: REGISTRY_VERSION, profiles: {} };
}

function normalizeRoot(value) {
  if (typeof value !== "string") return null;
  const root = value.trim();
  if (!ROOT_PATTERN.test(root) || RESERVED_ROOTS.has(root)) return null;
  return root;
}

function normalizeRoots(values) {
  if (!Array.isArray(values)) return [];
  return [...new Set(values.map(normalizeRoot).filter(Boolean))].sort();
}

function normalizePlugin(plugin) {
  if (!plugin || typeof plugin !== "object" || Array.isArray(plugin)) return null;
  const version = typeof plugin.version === "string" ? plugin.version : "";
  const detection = plugin.detection === "known" || plugin.detection === "approved"
    ? plugin.detection
    : "none";
  return { version, roots: normalizeRoots(plugin.roots), detection };
}

function normalizeRegistry(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || raw.version !== REGISTRY_VERSION) {
    throw new Error("gateway compatibility registry has an unsupported schema");
  }
  const profiles = {};
  if (!raw.profiles || typeof raw.profiles !== "object" || Array.isArray(raw.profiles)) {
    throw new Error("gateway compatibility registry profiles must be an object");
  }
  for (const [profile, value] of Object.entries(raw.profiles)) {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(profile)) throw new Error("invalid gateway compatibility profile");
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const plugins = {};
    if (value.plugins && typeof value.plugins === "object" && !Array.isArray(value.plugins)) {
      for (const [packageName, plugin] of Object.entries(value.plugins)) {
        const normalized = normalizePlugin(plugin);
        if (normalized) plugins[packageName] = normalized;
      }
    }
    if (Object.keys(plugins).length > 0) profiles[profile] = { plugins };
  }
  return { version: REGISTRY_VERSION, profiles };
}

function readRegistry(filePath, { strict = false } = {}) {
  if (!filePath) return emptyRegistry();
  try {
    const text = fs.readFileSync(filePath, "utf8");
    return normalizeRegistry(JSON.parse(text));
  } catch (error) {
    if (error && error.code === "ENOENT") return emptyRegistry();
    if (strict) throw error;
    return emptyRegistry();
  }
}

function registryEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function writeRegistry(filePath, registry) {
  if (!filePath) return;
  const normalized = normalizeRegistry(registry);
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(normalized, null, 2)}\n`, { mode: 0o600 });
    fs.renameSync(temporary, filePath);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

function setPlugin(registry, profile, packageName, version, roots, detection) {
  const next = normalizeRegistry(registry);
  const profileEntry = next.profiles[profile] || { plugins: {} };
  profileEntry.plugins[packageName] = {
    version: typeof version === "string" ? version : "",
    roots: normalizeRoots(roots),
    detection: detection === "known" || detection === "approved" ? detection : "none",
  };
  next.profiles[profile] = profileEntry;
  return next;
}

function deletePlugin(registry, profile, packageName) {
  const next = normalizeRegistry(registry);
  const profileEntry = next.profiles[profile];
  if (!profileEntry) return next;
  delete profileEntry.plugins[packageName];
  if (Object.keys(profileEntry.plugins).length === 0) delete next.profiles[profile];
  return next;
}

function rootsForProfile(registry, profile) {
  const roots = new Set();
  const plugins = registry.profiles[profile]?.plugins || {};
  for (const plugin of Object.values(plugins)) {
    for (const root of plugin.roots) roots.add(root);
  }
  return [...roots].sort();
}

function scanTextRoots(text) {
  const roots = new Set();
  if (typeof text !== "string") return [];
  ROOT_IN_TEXT.lastIndex = 0;
  let match;
  while ((match = ROOT_IN_TEXT.exec(text)) !== null) {
    const root = normalizeRoot(match[1]);
    if (root) roots.add(root);
  }
  return [...roots].sort();
}

function scanPluginRoots(packageDirectory) {
  const roots = new Set();
  const pending = [packageDirectory];
  let files = 0;
  let bytes = 0;
  while (pending.length > 0 && files < MAX_PLUGIN_FILES && bytes < MAX_SCAN_BYTES) {
    const directory = pending.pop();
    let entries;
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (files >= MAX_PLUGIN_FILES || bytes >= MAX_SCAN_BYTES) break;
      if (entry.name === "node_modules" || entry.name === ".pnpm-store") continue;
      const target = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        pending.push(target);
        continue;
      }
      if (!entry.isFile() || !/\.(?:cjs|css|html|js|mjs)$/i.test(entry.name)) continue;
      let stat;
      try { stat = fs.statSync(target); } catch { continue; }
      if (stat.size > MAX_SCAN_FILE_BYTES) continue;
      let content;
      try { content = fs.readFileSync(target, "utf8"); } catch { continue; }
      files += 1;
      bytes += Buffer.byteLength(content);
      for (const root of scanTextRoots(content)) roots.add(root);
    }
  }
  return [...roots].sort();
}

function packageDirectory(profileDirectory, packageName) {
  if (typeof packageName !== "string" || packageName.length === 0) return null;
  const candidate = path.resolve(profileDirectory, "node_modules", packageName);
  const root = path.resolve(profileDirectory);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) return null;
  try {
    const realRoot = fs.realpathSync(root);
    let realCandidate;
    try {
      realCandidate = fs.realpathSync(candidate);
    } catch {
      const linkStat = fs.lstatSync(candidate);
      if (!linkStat.isDirectory() && !linkStat.isSymbolicLink()) return null;
      let linkTarget = fs.readlinkSync(candidate);
      if (!path.isAbsolute(linkTarget)) {
        linkTarget = path.resolve(path.dirname(candidate), linkTarget);
      }
      realCandidate = linkTarget;
    }
    if (!fs.statSync(realCandidate).isDirectory()) return null;
    const rootForCheck = realRoot.endsWith(path.sep) ? realRoot : realRoot + path.sep;
    const candidateForCheck = realCandidate.endsWith(path.sep) ? realCandidate : realCandidate + path.sep;
    const normalizedRoot = rootForCheck.toLowerCase();
    const normalizedCandidate = candidateForCheck.toLowerCase();
    if (normalizedCandidate !== normalizedRoot && !normalizedCandidate.startsWith(normalizedRoot)) return null;
    return realCandidate;
  } catch {
    return null;
  }
}

function knownRoots(packageName) {
  return normalizeRoots(KNOWN_PLUGIN_ROOTS[packageName] || []);
}

function installedProfiles(profilesRoot) {
  try {
    return fs.readdirSync(profilesRoot, { withFileTypes: true })
      .filter(entry => entry.isDirectory() && /^[A-Za-z0-9_-]{1,64}$/.test(entry.name))
      .map(entry => entry.name);
  } catch {
    return [];
  }
}

function profileDependencies(profileDirectory) {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(profileDirectory, "package.json"), "utf8"));
    return manifest && typeof manifest.dependencies === "object" && !Array.isArray(manifest.dependencies)
      ? manifest.dependencies
      : {};
  } catch {
    return {};
  }
}

module.exports = {
  KNOWN_PLUGIN_ROOTS,
  REGISTRY_VERSION,
  RESERVED_ROOTS,
  ROOT_PATTERN,
  deletePlugin,
  emptyRegistry,
  knownRoots,
  normalizeRegistry,
  normalizeRoot,
  normalizeRoots,
  packageDirectory,
  profileDependencies,
  readRegistry,
  registryEqual,
  rootsForProfile,
  scanPluginRoots,
  scanTextRoots,
  setPlugin,
  writeRegistry,
};
