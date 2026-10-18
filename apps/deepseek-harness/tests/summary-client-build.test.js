"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { rewriteChangesSummaryClient } = require("../app/summary-client-compat.js");

const checker = path.join(__dirname, "../scripts/check-summary-client.mjs");
const compat = path.join(__dirname, "../app/summary-client-compat.js");
const fixture = path.join(__dirname, "fixtures/summary-client-bundle.js");
const source = fs.readFileSync(fixture, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "summary-build-gate-"));
const run = (args) => spawnSync(process.execPath, [checker, ...args], { encoding: "utf8", timeout: 5000 });
const rejected = (result, name) => {
  assert.equal(result.error, undefined, name);
  assert.notEqual(result.status, 0, name);
  assert.doesNotMatch(result.stdout, /build gate passed/, name);
};
try {
  const valid = run([compat, fixture]);
  assert.equal(valid.error, undefined);
  assert.equal(valid.status, 0, valid.stderr);
  assert.match(valid.stdout, /summary-client build gate passed/);
  assert.equal(fs.readFileSync(fixture, "utf8"), source, "the gate leaves its input unchanged");

  const unknown = path.join(temp, "unknown.js");
  fs.writeFileSync(unknown, "var unrelated = true;\n");
  rejected(run([compat, unknown]), "unknown bundles fail the CLI gate");

  const adapted = path.join(temp, "adapted.js");
  fs.writeFileSync(adapted, rewriteChangesSummaryClient(source));
  rejected(run([compat, adapted]), "a fresh build must contain the unmodified legacy client");

  const invalid = path.join(temp, "invalid.js");
  fs.writeFileSync(invalid, `${source}\nvar : ;\n`);
  rejected(run([compat, invalid]), "invalid script syntax fails after fragment recognition");

  const brokenCompat = path.join(temp, "no-rewrite.cjs");
  fs.writeFileSync(brokenCompat, 'exports.assertKnownChangesSummaryClient = () => "legacy";\nexports.rewriteChangesSummaryClient = source => source;\n');
  rejected(run([brokenCompat, fixture]), "a rewrite that changes nothing fails the gate");
  rejected(run([]), "missing paths fail the gate");
  rejected(run([compat, fixture, "extra"]), "extra paths fail the gate");

  if (process.platform !== "win32") {
    const buildText = fs.readFileSync(path.join(__dirname, "../scripts/build-fpk.sh"), "utf8");
    const gateStart = buildText.indexOf("summary_client_compat=");
    const gateEnd = buildText.indexOf('[ -f "$STAGED_SERVER/node_modules/yaml/package.json" ]', gateStart);
    assert.ok(gateStart >= 0 && gateEnd > gateStart, "the real Shell gate has a bounded extraction point");
    const shellGate = 'die() { printf "%s\\n" "$*" >&2; exit 1; }\nrequire_file() { [ -f "$1" ] || die "$2"; }\n'
      + buildText.slice(gateStart, gateEnd) + '\nprintf "%s\\n" "reached packaging"\n';
    const stagedServer = path.join(temp, "app/server");
    const stagedBundle = path.join(stagedServer, "node_modules/@deepseek-ai/dsh-client-ui-deliverables/lib/client.js");
    fs.mkdirSync(path.dirname(stagedBundle), { recursive: true });
    fs.copyFileSync(compat, path.join(temp, "app/summary-client-compat.js"));
    const runShellGate = () => spawnSync("/bin/sh", ["-c", shellGate], {
      encoding: "utf8", timeout: 5000,
      env: { ...process.env, SUMMARY_CLIENT_CHECKER: checker, PACKAGE_STAGE: temp, STAGED_SERVER: stagedServer },
    });
    fs.writeFileSync(stagedBundle, source);
    const shellValid = runShellGate();
    assert.equal(shellValid.error, undefined);
    assert.equal(shellValid.status, 0, shellValid.stderr);
    assert.match(shellValid.stdout, /build gate passed/);
    assert.match(shellValid.stdout, /reached packaging/);
    for (const body of ["var unrelated = true;\n", `${source}\nvar : ;\n`]) {
      fs.writeFileSync(stagedBundle, body);
      const shellInvalid = runShellGate();
      rejected(shellInvalid, "the actual Shell wrapper propagates a failed checker");
      assert.doesNotMatch(shellInvalid.stdout, /reached packaging/);
    }
  } else {
    process.stdout.write("SKIP: POSIX Shell wrapper execution on win32\n");
  }
  process.stdout.write("summary-client build gate tests passed\n");
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
