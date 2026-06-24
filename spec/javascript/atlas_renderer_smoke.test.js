"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const VIEW = path.join(__dirname, "..", "..", "app", "views", "enliterator", "atlas", "_viewer.html.erb");
const src = fs.readFileSync(VIEW, "utf8");
const scripts = Array.from(src.matchAll(/<script>\s*([\s\S]*?)\s*<\/script>/g)).map(m => m[1]);
const appScript = scripts.find(s => s.indexOf("window.EnliteratorAtlas =") !== -1);
if (!appScript) throw new Error("Atlas viewer script not found");

class FakeGraph {
  constructor() { this.nodes = new Map(); this.edges = new Map(); this.order = 0; }
  addNode(id, attrs) { this.nodes.set(id, Object.assign({}, attrs)); this.order = this.nodes.size; }
  addEdgeWithKey(id, s, t, attrs) { this.edges.set(id, Object.assign({ s, t }, attrs)); }
  hasNode(id) { return this.nodes.has(id); }
  getNodeAttributes(id) { return this.nodes.get(id); }
}

const context = {
  console,
  URL,
  window: {
    location: { href: "http://example.test/enliterator/atlas", pathname: "/enliterator/atlas" }
  },
  document: {
    readyState: "loading",
    addEventListener() {},
    querySelector() { return null; },
    createElement(tag) { return { tagName: tag, className: "", dataset: {}, addEventListener() {}, appendChild() {} }; }
  }
};
context.window.window = context.window;
context.window.document = context.document;
vm.runInNewContext(appScript, context);

const hooks = context.window.EnliteratorAtlas._test;
const vendor = {
  Graph: FakeGraph,
  forceAtlas2: {
    inferSettings() { return { gravity: 1 }; },
    assign(graph, opts) { graph.layout = opts; }
  }
};

const fixture = {
  meta: { mode: "overview" },
  nodes: [
    { id: "c:theses", kind: "context", label: "CHDS Theses", group: "theses", size: 2, degree: 2, x: 0, y: 0, label_priority: 100 },
    { id: "r:Widget:1", kind: "record", label: "FEMA preparedness thesis", group: "theses", size: 4, degree: 2, x: 12, y: 4, path: "status/Widget/1", label_priority: 80 },
    { id: "e:fema", kind: "entity", label: "FEMA", group: "advisor", size: 2, degree: 1, x: 60, y: 10, label_priority: 80 }
  ],
  edges: [
    { id: "edge-context", s: "r:Widget:1", t: "c:theses", key: "in-context", category: "context", w: 0.2, at: 1700000000 },
    { id: "edge-agent", s: "r:Widget:1", t: "e:fema", key: "advisor", category: "agent", w: 0.91, tier: "quality", verdict: "examiner:supported", at: 1700000200 }
  ]
};

let pass = 0, fail = 0;
function ok(cond, msg) { if (cond) pass++; else { fail++; console.error("  ✗ " + msg); } }

const model = hooks.buildGraphModel(fixture, vendor);
ok(model.graph.order === 3, "graph model includes fixture nodes");
ok(model.graph.edges.size === 2, "graph model includes fixture edges");
ok(model.rawEdges.get("edge-agent").category === "agent", "edge category survives graph model build");

const match = hooks.chooseSearchMatch(fixture.nodes, "fema");
ok(match && match.id === "e:fema", "search selects the matching node");

const next = hooks.modeUrl("/enliterator/atlas/data?mode=overview&context=theses", "focus", "e:fema");
ok(next.indexOf("mode=focus") !== -1, "mode switch URL updates mode");
ok(next.indexOf("focus=e%3Afema") !== -1, "mode switch URL includes selected focus id");
ok(next.indexOf("context=theses") !== -1, "mode switch URL preserves context");

const nodeHtml = hooks.inspectorForNode(fixture.nodes[1], fixture, false);
ok(nodeHtml.indexOf("FEMA preparedness thesis") !== -1, "node inspector includes label");
ok(nodeHtml.indexOf("Open record") !== -1, "record inspector includes open-record action");
ok(nodeHtml.indexOf("advisor") !== -1, "node inspector includes top edge type");

const edgeHtml = hooks.inspectorForEdge(fixture.edges[1], model);
ok(edgeHtml.indexOf("examiner:supported") !== -1, "edge inspector includes audit provenance");
ok(edgeHtml.indexOf("0.91") !== -1, "edge inspector includes confidence");

// Stage 1: the ranked neighbor list, projected client-side from the focus payload.
const rankFixture = {
  nodes: [
    { id: "r:Widget:1", kind: "record", label: "Center" },
    { id: "e:avery", kind: "entity", label: "J. L. Avery" },
    { id: "e:nassau",  kind: "entity", label: "Nassau County PD" }
  ],
  edges: [
    { s: "r:Widget:1", t: "e:avery", key: "advisor", category: "agent", w: 0.92 },
    { s: "r:Widget:1", t: "e:nassau",  key: "sponsor", category: "agent", w: 0.88 }
  ]
};
const rankRows = hooks.rankedNeighbors(rankFixture, "r:Widget:1");
ok(rankRows[0].relation === "advisor" && rankRows[0].confidence === 0.92, "ranked neighbors: advisor first, by relation");
ok(rankRows.some(r => r.label === "Nassau County PD"), "ranked neighbors: includes the sponsor neighbor");

// Stage 1: the inspector drawer renders a record's claims + provenance + known gaps.
const inspectPayload = {
  node: { label: "Thesis A", path: "status/Widget/1" },
  claims: [ { key: "summary", value: "S", tier: "quality", confidence: 0.86, asserted_at: 1719000000, verdict: "examiner:supported" } ],
  lacunae: [ { key: "authored_by", diagnosis: "defective_surrogate", note: "byline dropped" } ]
};
const recordHtml = hooks.inspectorForRecord(inspectPayload, false);
ok(recordHtml.indexOf("summary") !== -1, "record inspector shows a claim key");
ok(recordHtml.indexOf("Known gaps") !== -1, "record inspector shows the gaps section");
ok(recordHtml.indexOf("defective_surrogate") !== -1, "record inspector shows the lacuna diagnosis");
ok(recordHtml.indexOf("<script") === -1, "record inspector escapes content (no script injection)");

console.log((fail === 0 ? "✓ ALL " : "✗ ") + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
