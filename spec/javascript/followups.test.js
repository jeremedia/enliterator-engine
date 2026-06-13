"use strict";
// Lifts the REAL proseOf from the federated view block and proves the load-bearing
// streaming-safety property: the %%FOLLOWUPS%% sentinel (and any partial prefix of
// it arriving mid-stream) is NEVER part of the rendered prose.
const fs = require("fs");
const path = require("path");
const VIEW = path.join(__dirname, "..", "..", "app", "views", "enliterator", "conversation", "index.html.erb");
const src = fs.readFileSync(VIEW, "utf8");
const scriptSrc = src.slice(src.indexOf("<script>") + 8, src.lastIndexOf("</script>"));
function lift(name) {
  const sig = "function " + name + "(";
  const start = scriptSrc.indexOf(sig);
  if (start === -1) throw new Error("missing " + sig);
  const bs = scriptSrc.indexOf("{", start);
  let d = 0;
  for (let i = bs; i < scriptSrc.length; i++) {
    if (scriptSrc[i] === "{") d++;
    else if (scriptSrc[i] === "}") { d--; if (d === 0) return scriptSrc.slice(start, i + 1); }
  }
  throw new Error("unbalanced " + name);
}
const SENTINEL = "%%FOLLOWUPS%%";
const api = new Function(lift("proseOf") + "\nreturn { proseOf: proseOf };")();
let pass = 0, fail = 0;
function ok(c, m) { if (c) pass++; else { fail++; console.error("  ✗ " + m); } }

ok(api.proseOf("Answer here.") === "Answer here.", "no sentinel → unchanged");
ok(api.proseOf("Answer.\n\n" + SENTINEL + "\nQ1?\nQ2?") === "Answer.\n\n",
   "full sentinel → prose is everything before it");
ok(api.proseOf("Answer.\n\n%%FOLL").indexOf("%%FOLL") === -1, "partial sentinel prefix is withheld");
ok(api.proseOf("Answer.\n\n%%FOLL") === "Answer.\n\n", "withholding leaves clean prose");
ok(api.proseOf("done").indexOf("done") === 0, "ordinary text passes through");
// A trailing '%' is a 1-char prefix of the sentinel and is withheld (revealed on the
// next token / the final flush, which passes the COMPLETE text). The invariant that
// MUST hold: a literal or partial "%%FOLLOWUPS..." never appears in the returned prose.
ok(api.proseOf("It rose 5%%FOLLOWUPS%%\nQ?").indexOf("FOLLOWUPS") === -1, "sentinel after content is stripped");

console.log((fail === 0 ? "✓ ALL " : "✗ ") + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
