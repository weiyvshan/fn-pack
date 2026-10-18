import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { createRequire } from "node:module";

const [compatPath, bundlePath, ...extra] = process.argv.slice(2);
if (!compatPath || !bundlePath || extra.length) {
  throw new Error("Usage: check-summary-client.mjs <compat.js> <client.js>");
}
const require = createRequire(import.meta.url);
const { assertKnownChangesSummaryClient, rewriteChangesSummaryClient } = require(path.resolve(compatPath));
const source = fs.readFileSync(bundlePath, "utf8");
if (assertKnownChangesSummaryClient(source) !== "legacy") {
  throw new Error("expected the known legacy summary client bundle");
}
const adapted = rewriteChangesSummaryClient(source);
if (adapted === source || assertKnownChangesSummaryClient(adapted) !== "adapted") {
  throw new Error("summary client rewrite did not produce the reviewed adapted bundle");
}
new vm.Script(adapted, { filename: bundlePath });
console.log("summary-client build gate passed");
