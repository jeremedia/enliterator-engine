"use strict";
// Golden-output regression guard for the client-side markdown renderer
// (esc / inline / mdToHtml) in app/views/enliterator/conversation/index.html.erb.
//
// WHY: mdToHtml is SHARED by both the agentic-federation path and the single-shot
// path. Extending it (blockquotes, rules, tables, nested lists in v0.29) is the
// highest-regression-risk change in the chat UI upgrade. This script freezes the
// OLD behavior: every PRE-EXISTING markdown shape must render BYTE-IDENTICAL after
// the extension. If any golden case drifts, the new matchers are too greedy.
//
// HOW TO RUN:
//   node spec/javascript/md_golden.test.js
// To re-baseline INTENTIONALLY (only when a golden change is deliberate):
//   UPDATE_GOLDEN=1 node spec/javascript/md_golden.test.js
//
// This is also invoked from spec/javascript/md_golden_spec.rb so it runs inside
// `bundle exec rspec`.

const fs = require("fs");
const path = require("path");
const { mdToHtml } = require("./md_extract");

const GOLDEN_FILE = path.join(__dirname, "md_golden.json");

// ── PRE-EXISTING inputs: exercise EVERY old code path so the golden freezes the
//    full prior surface. These must render identically before and after. ──────
const PREEXISTING = {
  "atx headers h1..h6":
    "# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six",
  "bold and italic (star + underscore)":
    "A **bold** word, an *em* word, and an _under_ word.",
  "inline code":
    "Call `tend!(facet:)` to begin.",
  "a markdown link":
    "See [the about page](https://example.com/about) for the thesis.",
  "unordered list (dash and star)":
    "- first\n- second\n* third",
  "ordered list":
    "1. alpha\n2. beta\n3. gamma",
  "paragraphs separated by a blank line":
    "First paragraph here.\n\nSecond paragraph here.",
  "mixed: header, paragraph, list, paragraph":
    "## Findings\nThe collection shows three themes.\n- theme one\n- theme two\nAnd a closing line.",
  "html-significant characters get escaped":
    "Use <script> & \"quotes\" and a < b > c to test escaping.",
  "list immediately following a paragraph (no blank line)":
    "Here are the items:\n- a\n- b",
  "ordered then unordered (list type switch)":
    "1. one\n2. two\n- bullet\n- bullet two",
  "empty string": "",
  "only whitespace lines": "   \n\t\n  ",
  "bold containing escaped angle in text":
    "**<b>not html</b>** stays literal.",
  "link text with inline code-ish and asterisks (no nesting expected)":
    "A [link with *stars*](https://x.test) here.",
};

// ── NEW-syntax inputs: must produce the new elements (asserted by substring,
//    not frozen byte-for-byte, so we can refine rendering details later). ─────
const NEW_CASES = [
  { name: "blockquote single line", input: "> a quoted line", contains: ["<blockquote>"] },
  { name: "blockquote multi line", input: "> line one\n> line two", contains: ["<blockquote>", "line one", "line two"] },
  { name: "blockquote ends at blank line then paragraph",
    input: "> quoted\n\nafter", contains: ["<blockquote>", "</blockquote>", "<p>after</p>"] },
  { name: "horizontal rule ---", input: "above\n\n---\n\nbelow", contains: ["<hr>", "<p>above</p>", "<p>below</p>"] },
  { name: "horizontal rule *** ", input: "***", contains: ["<hr>"] },
  { name: "horizontal rule ___", input: "___", contains: ["<hr>"] },
  { name: "pipe table", input: "| Name | Count |\n| --- | --- |\n| Theme | 3 |\n| Other | 7 |",
    contains: ["<table>", "<thead>", "<th>Name</th>", "<th>Count</th>", "<tbody>", "<td>Theme</td>", "<td>3</td>"] },
  { name: "pipe table without outer pipes", input: "Name | Count\n--- | ---\nTheme | 3",
    contains: ["<table>", "<th>Name</th>", "<td>Theme</td>"] },
  // Nesting asserts STRUCTURE, not just substrings: the child <ul> must open
  // INSIDE the parent <li> (so a flat-rendered fallback would not satisfy it).
  { name: "nested unordered list", input: "- parent\n  - child\n- parent two",
    contains: ["<ul><li>parent<ul><li>child</li></ul></li><li>parent two</li></ul>"] },
  { name: "ordered list with nested unordered child",
    input: "1. one\n  - sub a\n  - sub b\n2. two",
    contains: ["<ol><li>one<ul><li>sub a</li><li>sub b</li></ul></li><li>two</li></ol>"] },
  { name: "single-column pipe table", input: "| Name |\n| --- |\n| Bob |",
    contains: ["<table>", "<th>Name</th>", "<td>Bob</td>"] },
  { name: "table cell carries inline formatting",
    input: "| Who |\n| --- |\n| **Bob** |",
    contains: ["<td><strong>Bob</strong></td>"] },
  { name: "ragged table row is padded to header width",
    input: "| A | B | C |\n|---|---|---|\n| 1 | 2 |",
    contains: ["<tr><td>1</td><td>2</td><td></td></tr>"] },
  { name: "blockquote carries inline formatting",
    input: "> see **this** and [x](https://x.test)",
    contains: ["<blockquote>see <strong>this</strong> and <a href=\"https://x.test\""] },
];

// ── NEGATIVE guards: shapes that LOOK like new syntax but must NOT fire it. ──
const NEGATIVE_CASES = [
  { name: "bold at line start is not a hr/blockquote",
    input: "**bold lead** then text", mustNotContain: ["<hr>", "<blockquote>"] },
  { name: "em at line start is not a hr",
    input: "*just emphasis* on a line", mustNotContain: ["<hr>"] },
  { name: "two dashes is not a hr",
    input: "--", mustNotContain: ["<hr>"] },
  { name: "a lone pipe line is not a table (no delimiter row)",
    input: "a | b", mustNotContain: ["<table>"] },
  { name: "a bare --- (no pipe) is an hr, never a table delimiter",
    input: "heading line\n---\nbody", mustNotContain: ["<table>"] },
  // The dangerous leak would be a RAW "<img …>" tag; the inert escaped text
  // "&lt;img …&gt;" (attribute words and all) is safe — assert no raw tag.
  { name: "html inside a blockquote stays escaped (no XSS)",
    input: "> <img src=x onerror=alert(1)>", mustNotContain: ["<img"] },
  { name: "html inside a table cell stays escaped (no XSS)",
    input: "| H |\n| --- |\n| <script>bad</script> |", mustNotContain: ["<script>bad"] },
];

function render(map) {
  const out = {};
  for (const k of Object.keys(map)) out[k] = mdToHtml(map[k]);
  return out;
}

let failures = 0;
function fail(msg) { failures++; console.error("  ✗ " + msg); }
function pass(msg) { console.log("  ✓ " + msg); }

const current = render(PREEXISTING);

// 1) Golden byte-identity for the pre-existing surface.
if (process.env.UPDATE_GOLDEN === "1" || !fs.existsSync(GOLDEN_FILE)) {
  fs.writeFileSync(GOLDEN_FILE, JSON.stringify(current, null, 2) + "\n");
  console.log(
    (fs.existsSync(GOLDEN_FILE) ? "[golden] wrote baseline → " : "[golden] created → ") +
    path.relative(path.join(__dirname, "..", ".."), GOLDEN_FILE)
  );
  // When (re)baselining we still run the new-case + negative assertions below.
}

console.log("PRE-EXISTING (must be byte-identical to the frozen golden):");
const golden = JSON.parse(fs.readFileSync(GOLDEN_FILE, "utf8"));
for (const k of Object.keys(PREEXISTING)) {
  if (!(k in golden)) { fail(k + " — no golden entry (re-baseline needed?)"); continue; }
  if (current[k] === golden[k]) pass(k);
  else {
    fail(k + " — OUTPUT DRIFTED");
    console.error("    golden : " + JSON.stringify(golden[k]));
    console.error("    actual : " + JSON.stringify(current[k]));
  }
}
// Catch a golden key that lost its input (shrinkage).
for (const k of Object.keys(golden)) {
  if (!(k in PREEXISTING)) fail(k + " — present in golden but no longer an input");
}

console.log("\nNEW SYNTAX (must produce the new elements):");
for (const c of NEW_CASES) {
  const html = mdToHtml(c.input);
  const missing = c.contains.filter((s) => html.indexOf(s) === -1);
  if (missing.length === 0) pass(c.name);
  else {
    fail(c.name + " — missing " + JSON.stringify(missing));
    console.error("    output : " + JSON.stringify(html));
  }
}

console.log("\nNEGATIVE GUARDS (new matchers must not fire on these):");
for (const c of NEGATIVE_CASES) {
  const html = mdToHtml(c.input);
  const wrong = c.mustNotContain.filter((s) => html.indexOf(s) !== -1);
  if (wrong.length === 0) pass(c.name);
  else {
    fail(c.name + " — unexpectedly contains " + JSON.stringify(wrong));
    console.error("    output : " + JSON.stringify(html));
  }
}

console.log("");
if (failures > 0) {
  console.error(failures + " failure(s).");
  process.exit(1);
}
console.log("All golden + new-syntax + negative cases passed.");
process.exit(0);
