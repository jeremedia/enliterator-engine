"use strict";
// No-dependency verification of the citation logic's load-bearing safety
// properties, lifting the REAL shipped functions from the view (same pattern as
// md_extract.js) and driving them against a minimal DOM shim. We test the
// pieces that don't need a full browser: citeUrl (URL construction), the
// CITE_MIN_LABEL floor + longest-first ordering in annotateCites, and the
// text-node-only / never-inside-a-link discipline of wrapFirstMatch.
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

// statusBase is a closure var set from ERB; inject it. NodeFilter is referenced
// by wrapFirstMatch's TreeWalker — provide the constant.
const factory = new Function(
  "SOURCE_PATH_BASE", "encodeURIComponent", "document", "NodeFilter", "window",
  lift("citeUrl") + "\n" + lift("wrapFirstMatch") + "\n" + lift("makeCiteChip") + "\n" + lift("buildCitePop") + "\n" +
  // v0.32: wrapFirstMatch now wraps the match via makeAskLink. Lift it too; its
  // click handler (go → askInComposer) is never invoked here, so input/autosize
  // need not be provided.
  lift("makeAskLink") + "\n" +
  "return { citeUrl: citeUrl, wrapFirstMatch: wrapFirstMatch };"
);

let pass = 0, fail = 0;
function ok(cond, msg) { if (cond) { pass++; } else { fail++; console.error("  ✗ " + msg); } }

// ── citeUrl: prefers entry, else statusBase + /Type/id ──────────────────────
{
  const api = factory("/enliterator/status", encodeURIComponent, null, null, null);
  ok(api.citeUrl({ entry: "/enliterator/status/DocMetum/7" }) === "/enliterator/status/DocMetum/7",
     "citeUrl uses the tool-provided entry path verbatim");
  ok(api.citeUrl({ type: "DocMetum", id: "7" }) === "/enliterator/status/DocMetum/7",
     "citeUrl reconstructs statusBase + /Type/id when no entry");
  ok(api.citeUrl({ type: "A B", id: "x/y" }) === "/enliterator/status/A%20B/x%2Fy",
     "citeUrl URL-encodes type and id");
}

// ── wrapFirstMatch: text-node-only, never inside <a>, escaped by construction ──
// Minimal DOM shim: Text + Element with the bits the function touches
// (childNodes, nodeValue, splitText, parentNode, closest, insertBefore,
// createTreeWalker SHOW_TEXT). Built just enough to be faithful.
function makeDom() {
  const NodeFilter = { SHOW_TEXT: 4 };
  function Text(v) { this.nodeType = 3; this.nodeValue = v; this.parentNode = null; }
  Text.prototype.splitText = function (off) {
    const tail = new Text(this.nodeValue.slice(off));
    this.nodeValue = this.nodeValue.slice(0, off);
    const p = this.parentNode;
    tail.parentNode = p;
    const idx = p.childNodes.indexOf(this);
    p.childNodes.splice(idx + 1, 0, tail);
    return tail;
  };
  function Element(tag) { this.nodeType = 1; this.tagName = tag.toUpperCase(); this.childNodes = []; this.parentNode = null; this.attrs = {}; this.className = ""; this._listeners = {}; }
  Element.prototype.appendChild = function (n) { n.parentNode = this; this.childNodes.push(n); return n; };
  Element.prototype.insertBefore = function (n, ref) {
    n.parentNode = this;
    const idx = ref ? this.childNodes.indexOf(ref) : this.childNodes.length;
    this.childNodes.splice(idx === -1 ? this.childNodes.length : idx, 0, n);
    return n;
  };
  Element.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
  Element.prototype.getAttribute = function (k) { return this.attrs[k]; };
  Element.prototype.addEventListener = function (e, f) { (this._listeners[e] = this._listeners[e] || []).push(f); };
  Element.prototype.replaceChild = function (newN, oldN) {
    const idx = this.childNodes.indexOf(oldN);
    if (idx !== -1) { newN.parentNode = this; this.childNodes.splice(idx, 1, newN); oldN.parentNode = null; }
    return oldN;
  };
  Object.defineProperty(Element.prototype, "textContent", {
    get() { return this.childNodes.map(c => c.nodeType === 3 ? c.nodeValue : c.textContent).join(""); },
    set(v) { this.childNodes = [ Object.assign(new Text(v), { parentNode: this }) ]; }
  });
  // closest: walk up matching tagName 'a' or className containing enl-cite
  Element.prototype.closest = function (sel) {
    let n = this;
    const wantA = sel.indexOf("a") !== -1, wantCite = sel.indexOf("enl-cite") !== -1,
          wantAsk = sel.indexOf("enl-ask") !== -1;
    while (n) {
      if (n.nodeType === 1) {
        if (wantA && n.tagName === "A") return n;
        if (wantCite && (n.className || "").indexOf("enl-cite") !== -1) return n;
        if (wantAsk && (n.className || "").indexOf("enl-ask") !== -1) return n;
      }
      n = n.parentNode;
    }
    return null;
  };
  const document = {
    createElement: (t) => new Element(t),
    createTreeWalker(root, what) {
      const texts = [];
      (function rec(n) { n.childNodes.forEach(c => { if (c.nodeType === 3) texts.push(c); else rec(c); }); })(root);
      let i = -1;
      return { nextNode() { i++; return i < texts.length ? texts[i] : null; } };
    }
  };
  return { document, NodeFilter, Text, Element };
}

{
  const dom = makeDom();
  const api = factory("/enliterator/status", encodeURIComponent, dom.document, dom.NodeFilter,
                      { location: {} });
  // root: <div> "see United States Coast Guard here" </div>
  const root = new dom.Element("div");
  const t = new dom.Text("see United States Coast Guard here");
  root.appendChild(t);
  const cand = { label: "United States Coast Guard", ref: 1, rec: { type: "DocMetum", id: "7", label: "United States Coast Guard" } };
  const placed = api.wrapFirstMatch(root, "United States Coast Guard", cand);
  ok(placed === true, "wrapFirstMatch returns true when the label is present");
  // a chip <button class=enl-cite> was inserted right after the matched text
  const chips = root.childNodes.filter(n => n.nodeType === 1 && (n.className || "").indexOf("enl-cite") !== -1);
  ok(chips.length === 1, "exactly one chip inserted");
  ok(chips[0].tagName === "BUTTON", "the chip is a <button> (keyboard-accessible)");
  ok(chips[0].getAttribute("data-ref") === "1", "chip carries data-ref");
  ok(chips[0].textContent === "1", "chip shows the ref number");
  // the original text is intact, just split around the chip
  ok(root.textContent === "see United States Coast Guard1 here",
     "text preserved, chip placed immediately after the match");
  // v0.32: the matched label is now ALSO wrapped as an "ask about this" affordance
  const asks = root.childNodes.filter(n => n.nodeType === 1 && (n.className || "").indexOf("enl-ask") !== -1);
  ok(asks.length === 1, "the matched label is wrapped as one enl-ask affordance");
  ok(asks[0].textContent === "United States Coast Guard", "ask span carries the matched text (original case)");
  ok(asks[0].getAttribute("title").indexOf("United States Coast Guard") !== -1, "ask carries the follow-up question");

  // never matches inside a link
  const dom2 = makeDom();
  const api2 = factory("/enliterator/status", encodeURIComponent, dom2.document, dom2.NodeFilter, { location: {} });
  const root2 = new dom2.Element("div");
  const a = new dom2.Element("a"); a.setAttribute("href", "/x");
  a.appendChild(new dom2.Text("United States Coast Guard"));
  root2.appendChild(a);
  const placed2 = api2.wrapFirstMatch(root2, "United States Coast Guard", cand);
  ok(placed2 === false, "wrapFirstMatch refuses to wrap text inside an existing <a> (no nested/anchor-breaking chips)");
}

console.log((fail === 0 ? "✓ ALL " : "✗ ") + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
