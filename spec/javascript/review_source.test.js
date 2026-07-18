"use strict";
// v0.62: the Review focus view's source pane — proves the pure segmentation/meta helpers
// behind window.EnliteratorReviewSource._test: lossless case-insensitive occurrence
// splitting, the 6..200-char needle guard, and the truncation/match meta line.
// (v0.63: the render path is markdown via the shared md client — mdToHtml escapes
// FIRST, guarded by md_golden.test.js — and highlighting walks rendered TEXT NODES;
// lossless segmentation remains the property that keeps marking injection-free.)
const fs = require("fs");
const path = require("path");
const VIEW = path.join(__dirname, "..", "..", "app", "views", "enliterator", "review", "index.html.erb");
const MD = path.join(__dirname, "..", "..", "app", "views", "enliterator", "shared", "_md_client.html.erb");
const src = fs.readFileSync(VIEW, "utf8");
// The raw ERB script contains the `<%= render "…/md_client" %>` tag — substitute the
// partial's actual JS (what the server renders there), mirroring the shipped script.
const scriptSrc = src.slice(src.indexOf("<script>") + 8, src.lastIndexOf("</script>"))
  .replace(/<%=\s*render[^%]*%>/, fs.readFileSync(MD, "utf8"));
if (scriptSrc.includes("<%")) {
  console.error("  ✗ unexpected ERB left in the extracted script");
  process.exit(1);
}

let pass = 0, fail = 0;
function ok(c, m) { if (c) pass++; else { fail++; console.error("  ✗ " + m); } }

const fakeWindow = {};
const fakeDocument = { querySelector: () => null };   // no dialog → wiring no-ops
try {
  new Function("window", "document", scriptSrc)(fakeWindow, fakeDocument);
  ok(true, "source-pane script runs on a bare page");
} catch (e) {
  ok(false, "source-pane script must no-op without a dialog (threw: " + e.message + ")");
}
ok(!!(fakeWindow.EnliteratorReviewSource && fakeWindow.EnliteratorReviewSource._test),
   "_test hooks exposed");

const t = fakeWindow.EnliteratorReviewSource._test;
const joined = (segs) => segs.map((s) => s.text).join("");

// Case-insensitive matching that preserves the SOURCE's casing in the matched slice.
const text = "A grace note opens it. Later the GRACE NOTE returns, ungraceful.";
const segs = t.splitOccurrences(text, "grace note");
ok(t.matchCount(segs) === 2, "finds both casings");
ok(segs.some((s) => s.match && s.text === "grace note"), "keeps lowercase source casing");
ok(segs.some((s) => s.match && s.text === "GRACE NOTE"), "keeps uppercase source casing");
ok(joined(segs) === text, "segmentation is lossless (reassembles byte-for-byte)");

// Needle guard: too short / too long / empty → one non-matching segment, text intact.
ok(t.matchCount(t.splitOccurrences("abcde abcde", "abc")) === 0, "needles under 6 chars are skipped");
ok(t.matchCount(t.splitOccurrences("x".repeat(500), "x".repeat(201))) === 0, "needles over 200 chars are skipped");
ok(t.matchCount(t.splitOccurrences("anything", "")) === 0, "empty needle is skipped");
ok(joined(t.splitOccurrences("anything", "")) === "anything", "skipped needle leaves text intact");

// HTML-looking content stays inert data: it segments losslessly, never gets parsed.
const spiky = 'before <script>alert("x")<\/script> after grace note here';
const spikySegs = t.splitOccurrences(spiky, "grace note");
ok(joined(spikySegs) === spiky, "markup in the source survives as plain text segments");
ok(t.matchCount(spikySegs) === 1, "matching still works around markup-looking text");

// The meta line: truncation cut + match count, honestly worded.
ok(t.sourceMeta({ text: "aaaa", truncated: true, length: 100 }, 2)
     .indexOf("showing the first 4 of 100 characters") === 0, "truncation names the cut");
ok(t.sourceMeta({ text: "aaaa", truncated: false, length: 4 }, 3)
     .indexOf("claim value found 3×") === 0, "match count leads when nothing is cut");
ok(t.sourceMeta({ text: "aaaa", truncated: false, length: 4 }, 0)
     .indexOf("not found verbatim") >= 0, "zero matches is stated, not hidden");

console.log((fail === 0 ? "✓ ALL " : "✗ ") + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
