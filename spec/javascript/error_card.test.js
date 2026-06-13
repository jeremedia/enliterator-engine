"use strict";
// No-dependency verification of the v0.30 actionable error card (renderErrorCard),
// lifting the REAL shipped function from the view (same pattern as cite_logic.test.js
// / md_golden) and driving it against a minimal DOM shim. We test the load-bearing
// properties that don't need a full browser:
//   (1) message-only payload  → only .enl-error__msg, no detail/where/hint nodes;
//   (2) full payload          → detail/where/hint nodes with the right text;
//   (3) injection payload     → the value is INERT (set via textContent; the card's
//                               innerHTML contains NO live <img/<script>, only the
//                               escaped/text form) — the XSS-safety proof.
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

// renderErrorCard's closure refs: `document` (createElement), `thread` (the bare
// fallback append when neither els.md nor els.turn resolves), `ensureAnswer` (called
// only when els.md is absent), and `followStream` (the v0.34 auto-scroll hook, called
// after placement — orthogonal to the card's DOM/XSS properties, so we inject a
// no-op). We drive the els.md / els.turn placement branches directly (els always
// carries md or turn here), so ensureAnswer is a no-op probe that records if it were
// ever reached unexpectedly.
let ensureAnswerCalls = 0;
const noop = function () {};
const factory = new Function(
  "document", "thread", "ensureAnswer", "followStream",
  lift("renderErrorCard") + "\nreturn { renderErrorCard: renderErrorCard };"
);

let pass = 0, fail = 0;
function ok(cond, msg) { if (cond) { pass++; } else { fail++; console.error("  ✗ " + msg); } }

// ── Minimal DOM shim ─────────────────────────────────────────────────────────
// Element with the bits renderErrorCard touches: className, appendChild,
// textContent (get/set), and an innerHTML GETTER that serializes children as a
// browser would (text escaped, tags rendered) — so the injection test can assert
// that NO live tag was ever created from a payload value set via textContent.
function makeDom() {
  function Text(v) { this.nodeType = 3; this.nodeValue = v; this.parentNode = null; }
  function escapeText(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function Element(tag) {
    this.nodeType = 1; this.tagName = tag.toUpperCase();
    this.childNodes = []; this.parentNode = null; this.className = "";
  }
  Element.prototype.appendChild = function (n) { n.parentNode = this; this.childNodes.push(n); return n; };
  Object.defineProperty(Element.prototype, "textContent", {
    get() { return this.childNodes.map(c => c.nodeType === 3 ? c.nodeValue : c.textContent).join(""); },
    set(v) { this.childNodes = [ Object.assign(new Text(v), { parentNode: this }) ]; }
  });
  // Browser-faithful serialization: text nodes are HTML-escaped, elements emit
  // their tag. A value set via textContent therefore can NEVER serialize to a
  // live child tag — that is exactly the XSS property we assert.
  Object.defineProperty(Element.prototype, "innerHTML", {
    get() {
      return this.childNodes.map(function ser(c) {
        if (c.nodeType === 3) return escapeText(c.nodeValue);
        var inner = c.childNodes.map(ser).join("");
        return "<" + c.tagName.toLowerCase() +
               (c.className ? ' class="' + c.className + '"' : "") +
               ">" + inner + "</" + c.tagName.toLowerCase() + ">";
      }.bind(this)).join("");
    }
  });
  const document = { createElement: (t) => new Element(t) };
  return { document, Element };
}

// Find direct child of the card by class.
function childByClass(card, cls) {
  return card.childNodes.filter(n => n.nodeType === 1 && (n.className || "") === cls);
}

// ── (1) message-only payload → only the headline ─────────────────────────────
{
  const dom = makeDom();
  const thread = { scrollTop: 0, scrollHeight: 100, appendChild() {} };
  const api = factory(dom.document, thread, function () { ensureAnswerCalls++; }, noop);
  const els = { md: new dom.Element("div"), turn: new dom.Element("div") };
  api.renderErrorCard(els, { message: "I lost the connection — please try again." });
  // The card is the sole child of els.md (typing placeholder cleared, card appended).
  const card = els.md.childNodes.find(n => n.nodeType === 1 && n.className === "enl-error");
  ok(!!card, "card rendered into the answer container (els.md)");
  ok(childByClass(card, "enl-error__msg").length === 1, "message-only: exactly one __msg node");
  ok(childByClass(card, "enl-error__msg")[0].textContent === "I lost the connection — please try again.",
     "message-only: __msg carries the message text");
  ok(childByClass(card, "enl-error__detail").length === 0, "message-only: NO __detail node");
  ok(childByClass(card, "enl-error__where").length === 0, "message-only: NO __where node");
  ok(childByClass(card, "enl-error__hint").length === 0, "message-only: NO __hint node");
}

// ── (1b) absent message → the fallback headline ──────────────────────────────
{
  const dom = makeDom();
  const thread = { scrollTop: 0, scrollHeight: 100, appendChild() {} };
  const api = factory(dom.document, thread, function () {}, noop);
  const els = { md: new dom.Element("div") };
  api.renderErrorCard(els, {});
  const card = els.md.childNodes.find(n => n.nodeType === 1 && n.className === "enl-error");
  ok(childByClass(card, "enl-error__msg")[0].textContent === "Something went wrong",
     "absent message → 'Something went wrong' fallback");
}

// ── (2) full payload → detail / where / hint nodes, right text ───────────────
{
  const dom = makeDom();
  const thread = { scrollTop: 0, scrollHeight: 100, appendChild() {} };
  const api = factory(dom.document, thread, function () {}, noop);
  const els = { md: new dom.Element("div") };
  api.renderErrorCard(els, {
    message: "conversation failed",
    detail:  "StandardError: upstream request timed out",
    where:   "model call · CHDS Theses · bedrock-sonnet",
    hint:    "The LLM gateway timed out — retry, or the tier is slow."
  });
  const card = els.md.childNodes.find(n => n.nodeType === 1 && n.className === "enl-error");
  ok(childByClass(card, "enl-error__msg")[0].textContent === "conversation failed",
     "full: __msg carries the message floor");
  ok(childByClass(card, "enl-error__detail")[0].textContent === "StandardError: upstream request timed out",
     "full: __detail carries 'Class: message'");
  ok(childByClass(card, "enl-error__where")[0].textContent === "model call · CHDS Theses · bedrock-sonnet",
     "full: __where carries the humanized location");
  ok(childByClass(card, "enl-error__hint")[0].textContent === "→ The LLM gateway timed out — retry, or the tier is slow.",
     "full: __hint is prefixed with '→ ' (the actionable line)");
}

// ── (3) injection payload → INERT (textContent, not innerHTML) ───────────────
// detail/where/hint carry markup that WOULD execute if assigned via innerHTML.
// Because renderErrorCard uses textContent, the card's serialized innerHTML must
// contain NO live <img/<script> tag — only the escaped/text form.
{
  const dom = makeDom();
  const thread = { scrollTop: 0, scrollHeight: 100, appendChild() {} };
  const api = factory(dom.document, thread, function () {}, noop);
  const els = { md: new dom.Element("div") };
  const evil = '<img src=x onerror=alert(1)>';
  const evil2 = '<script>alert(2)</script>';
  api.renderErrorCard(els, {
    message: "broke " + evil,
    detail:  "StandardError: " + evil,
    where:   "model call " + evil2,
    hint:    "retry " + evil2
  });
  const card = els.md.childNodes.find(n => n.nodeType === 1 && n.className === "enl-error");
  const html = card.innerHTML;
  // No live opening tags from payload data anywhere in the card's serialized
  // HTML — the `<` of every payload value is escaped to `&lt;`, so a tag can
  // never open. (The bare substring "onerror=" surviving INSIDE an already-
  // escaped "&lt;img … onerror=… &gt;" is inert — it is text, not an attribute
  // on a live element — so we assert on the tag-open, which is the real hole.)
  ok(html.indexOf("<img") === -1, "injection: no live <img tag in the card HTML");
  ok(html.indexOf("<script") === -1, "injection: no live <script tag in the card HTML");
  // Belt-and-suspenders: no UNescaped "<" from a payload value reaches the HTML
  // (every payload "<" must appear only as "&lt;"). The card's own structural
  // tags use class="enl-error*", so any "<" not part of those is a leak.
  ok(/<(?!\/?div\b)/i.test(html) === false, "injection: the only live tags are the card's own <div>s (no payload tag opened)");
  // The text IS present, in escaped form — the payload was rendered, just inertly.
  ok(html.indexOf("&lt;img") !== -1, "injection: the <img text survives as escaped &lt;img (rendered, inert)");
  ok(html.indexOf("&lt;script&gt;") !== -1, "injection: the <script> text survives as escaped (rendered, inert)");
  // And the live DOM agrees: every payload value lives as a Text node.
  ok(childByClass(card, "enl-error__detail")[0].childNodes.every(n => n.nodeType === 3),
     "injection: __detail contains only Text nodes (set via textContent)");
}

// ── (4) fallback placement → appends to els.turn when no answer container ────
{
  const dom = makeDom();
  const thread = { scrollTop: 0, scrollHeight: 100, appendChild() {} };
  // ensureAnswer here would set els.md; simulate the real one assigning md so the
  // md branch is taken (matching the view). But we test the els.turn fallback by
  // making ensureAnswer a no-op (md stays absent) and giving only a turn.
  const api = factory(dom.document, thread, function () { /* no-op: md stays unset */ }, noop);
  const els = { turn: new dom.Element("div") };
  api.renderErrorCard(els, { message: "fallback" });
  const card = els.turn.childNodes.find(n => n.nodeType === 1 && n.className === "enl-error");
  ok(!!card, "fallback: card appended to els.turn when no answer container resolves");
}

console.log((fail === 0 ? "✓ ALL " : "✗ ") + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
