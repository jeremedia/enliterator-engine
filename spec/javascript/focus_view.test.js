"use strict";
// v0.62: the Focus-view driver (the layout's shared <script>) — proves the init guard
// no-ops on a page with no focus dialog, and exercises the pure helpers behind
// window.EnliteratorFocus._test (navigation clamping, keyboard suppression inside
// form fields, position labeling, the Map lane's %{target} substitution).
const fs = require("fs");
const path = require("path");
const VIEW = path.join(__dirname, "..", "..", "app", "views", "layouts", "enliterator", "application.html.erb");
const src = fs.readFileSync(VIEW, "utf8");
const scriptSrc = src.slice(src.indexOf("<script>") + 8, src.lastIndexOf("</script>"));

let pass = 0, fail = 0;
function ok(c, m) { if (c) pass++; else { fail++; console.error("  ✗ " + m); } }

// A bare page: querySelector finds no focus dialog. If the guard leaked, the driver
// would touch document.body / location / CustomEvent — none provided → loud throw.
const fakeWindow = {};
const fakeDocument = { querySelector: () => null };
try {
  new Function("window", "document", scriptSrc)(fakeWindow, fakeDocument);
  ok(true, "driver runs on a bare page");
} catch (e) {
  ok(false, "driver must no-op without a focus dialog (threw: " + e.message + ")");
}
ok(!!(fakeWindow.EnliteratorFocus && fakeWindow.EnliteratorFocus._test),
   "_test hooks exposed even when inert");

const t = fakeWindow.EnliteratorFocus._test;

// targetIndex — string-keyed lookup, tolerant of numbers and null.
ok(t.targetIndex(["author", "keywords"], "keywords") === 1, "targetIndex finds a key");
ok(t.targetIndex(["author"], "ghost") === -1, "targetIndex misses honestly");
ok(t.targetIndex(["author"], null) === -1, "targetIndex(null) is -1");
ok(t.targetIndex(["7", "8"], 8) === 1, "targetIndex coerces numeric keys to strings");

// clampStep — no wrap at either end.
ok(t.clampStep(0, -1, 5) === 0, "clampStep pins at the start");
ok(t.clampStep(4, 1, 5) === 4, "clampStep pins at the end");
ok(t.clampStep(2, 1, 5) === 3, "clampStep advances");
ok(t.clampStep(2, -1, 5) === 1, "clampStep retreats");

// keyAction — arrows navigate, but NEVER while typing in a field.
ok(t.keyAction("ArrowLeft", "DIV") === -1, "ArrowLeft steps back");
ok(t.keyAction("ArrowRight", "BODY") === 1, "ArrowRight steps forward");
ok(t.keyAction("ArrowLeft", "INPUT") === null, "arrows suppressed in INPUT");
ok(t.keyAction("ArrowRight", "TEXTAREA") === null, "arrows suppressed in TEXTAREA");
ok(t.keyAction("ArrowLeft", "SELECT") === null, "arrows suppressed in SELECT");
ok(t.keyAction("Enter", "DIV") === null, "Enter is never a navigation (or verdict) key");

// positionLabel — 1-based "n of N".
ok(t.positionLabel(2, 15) === "3 of 15", "positionLabel is 1-based");
ok(t.positionLabel(0, 1) === "1 of 1", "positionLabel handles a single item");

// mapConsequence — the Map lane's live %{target} substitution.
const tpl = 'Files "x" as a variant (UF) of "%{target}" — a USE reference.';
ok(t.mapConsequence(tpl, "central_metaphor").indexOf('"central_metaphor"') > 0,
   "mapConsequence substitutes the typed target");
ok(t.mapConsequence(tpl, "  ").indexOf('"…"') > 0, "blank target shows an ellipsis");
ok(t.mapConsequence(tpl, null).indexOf("%{target}") === -1, "placeholder never leaks");

console.log((fail === 0 ? "✓ ALL " : "✗ ") + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
