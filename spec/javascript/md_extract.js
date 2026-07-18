"use strict";
// Extract the three client-side markdown helpers (esc / inline / mdToHtml) from
// the SHARED partial (v0.63: hoisted out of the conversation view so the Review
// focus view's source pane renders the same markdown — one shipped copy), so the
// golden test exercises the REAL shipped code rather than a drifting copy. The
// partial is pure vanilla JS with no ERB, so we can lift each function by name
// and brace-balancing.
//
// This module exports the extracted functions; md_golden.test.js drives them.

const fs = require("fs");
const path = require("path");

const VIEW = path.join(
  __dirname, "..", "..",
  "app", "views", "enliterator", "shared", "_md_client.html.erb"
);

// Pull the named function declaration out of `src` by finding `function NAME(`
// and balancing braces from the first `{`. Returns the full `function … { … }`
// text. Throws if not found or unbalanced (a loud failure — rule 3).
function liftFunction(src, name) {
  const sig = "function " + name + "(";
  const start = src.indexOf(sig);
  if (start === -1) throw new Error("could not find `" + sig + "` in the view");
  const braceStart = src.indexOf("{", start);
  if (braceStart === -1) throw new Error("no `{` after `" + sig + "`");
  let depth = 0;
  for (let i = braceStart; i < src.length; i++) {
    const ch = src[i];
    // Skip string/template/regex literals would be ideal, but these three
    // functions contain only regex literals and template-free strings whose
    // braces are balanced or absent; a plain brace count is correct here and
    // is asserted by the require() succeeding + the golden cases passing.
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error("unbalanced braces lifting `" + name + "`");
}

// The partial IS the script body — pure JS, no <script> wrapper, no ERB.
const scriptSrc = fs.readFileSync(VIEW, "utf8");
if (scriptSrc.includes("<%")) {
  throw new Error("the md_client partial must stay pure JS (found an ERB tag)");
}

const escSrc = liftFunction(scriptSrc, "esc");
const inlineSrc = liftFunction(scriptSrc, "inline");
const mdSrc = liftFunction(scriptSrc, "mdToHtml");

// Evaluate the three functions in a fresh scope (esc/inline are referenced by
// mdToHtml/inline, so declare them together).
const factory = new Function(
  escSrc + "\n" + inlineSrc + "\n" + mdSrc + "\n" +
  "return { esc: esc, inline: inline, mdToHtml: mdToHtml };"
);

module.exports = factory();
module.exports._sources = { escSrc, inlineSrc, mdSrc };
