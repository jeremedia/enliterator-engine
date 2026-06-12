# v0.28 — The Reference Desk (the conversational surface, made agentic)

*Design doc — 2026-06-12. Status: PROPOSED, pre-implementation. Gated on Jeremy's review.*

## Context

The engine's tenth-ish surface is **Chat** (`/enliterator/chat`) — today a single-shot
reference interview: embed the question, retrieve 5 records, stuff their claims into one
prompt, stream prose with source chips (`Enliterator::Conversation`, 206 lines). It works,
but it does not *use* the collection's deepest affordances. Two days ago we shipped the
v0.26 MCP surface — 14 tools that give an agent calibrated, provenance-bearing hands on the
collection. The chat doesn't call them.

This design upgrades Chat into **the Reference Desk**: a patron asks in plain language; an
agent works the catalog on their behalf — searching, opening entries, checking provenance,
quoting sources — and shows its work as **inline widgets**, not a wall of text. Per-context
agents give each collection its own reference librarian.

**The product constraint (Jeremy, 2026-06-12):** a URL we can hand to CHDS staff and the
FEDLINK audience that *works in any browser with no account and no install*, and that we
*know* will hold up in the room. External MCP-host rendering (Claude Desktop, ChatGPT) is
"eventually, yes" — a later hinge, not the demo. **Deadline:** FEDLINK (Library of
Congress), 2026-07-14.

## Goals

1. **Agentic.** The chat reasons across multiple tool calls (`search` → `record_entry` →
   `provenance` → `quote`), not one retrieval pass.
2. **Widgets.** Tool results render as self-contained inline HTML — record cards, provenance
   chains, trajectory, accuracy — interleaved with the prose.
3. **Per-context agents.** Each context gets a system prompt + tool subset + staffing tier.
4. **A public, accountless, reliable URL.** The branded host *is* the demo.
5. **Build the widget layer ONCE** as pure functions of tool-output JSON, so the same
   renderers later wrap as MCP Apps `ui://` resources for external hosts — no rebuild.

## Non-goals (YAGNI)

- **External MCP-host rendering** (the `ui://` wrapping) — designed-for, not built in v0.28.
- **Thread persistence** beyond the session — the demo is ephemeral; durable threads later.
- **Uploads, voice, multimodal.**
- **Adopting RubyLLM or the AG-UI/ChatKit SDKs.** We borrow AG-UI's *event vocabulary* and
  MCP Apps' *widget shape*; we keep our own LLM adapter + staffing spine (that spine is the
  provenance argument).
- **Governed writes in the public agent.** `propose_term` / `flag_claim` are NOT in the
  public toolset — the public Reference Desk is read-only (see Safety).

## Architecture

Five components. Most of this already exists; the table marks reuse honestly.

| Component | Status | What |
|---|---|---|
| Tool surface | **REUSE** | `Enliterator::Mcp.listing` (name/description/inputSchema → OpenAI function defs) + `Mcp.dispatch(name, args)` as the executor. The chat agent and the external MCP server share ONE tool definition. |
| Agent loop | **NEW** | `Enliterator::Conversation::Agent` — drives model↔tools rounds until a final answer, bounded by a step cap. |
| Adapter tool-loop call | **EXTEND** | `Adapters::LLM::Gateway#converse_with_tools(messages:, tools:, stream:)` — the missing primitive. Today the adapter does forced-single-tool (`decide`) and no-tool (`converse`); this adds optional-multi-tool with tool-result messages fed back. The parsing helpers (`first_tool_call`, `arguments_of`) already exist; we generalize from one forced call to N optional calls + the `tool` result role. |
| Widget renderers | **NEW** | `Enliterator::Chat::Widget` — pure functions `(tool_name, result_json) → HTML`, one per widget-worthy tool, built on the v0.19 component tokens (inline, no CDN). |
| Per-context agent config | **NEW (small)** | `Enliterator::Chat::Agent.for(context)` → `{ system_prompt, tools, tier }`, resolved from the existing context model + staffing policy. |
| Transport | **EXTEND** | `conversation_controller#stream` drives the loop and streams a mixed event stream (text deltas + widget blocks + tool-status), event shapes borrowed from AG-UI. |

### Data flow (one turn)

```
user question
  └─ resolve the context agent  →  { system_prompt, tools: [subset of the 14], tier }
       └─ Conversation::Agent loop (max N rounds):
            model(messages, tools) ──► text deltas        → SSE: TEXT_MESSAGE_CONTENT
                                   └─► tool_call(s)        → SSE: TOOL_CALL_START (status pill)
                 Mcp.dispatch(name, args) → result JSON
                     ├─► widget HTML (pure renderer)       → SSE: TOOL_CALL_RESULT (widget block)
                     └─► tool-result message  ──► fed back to the model
            … until the model emits a final answer        → SSE: DONE
```

The answer arrives as prose **interleaved with the actual record cards, provenance chains,
and trajectory the agent consulted** — every assertion shows its receipts inline.

### The widget model

A widget is a **pure function of a tool's JSON output → self-contained HTML.** No network,
no state, no CDN — inline styles from the v0.19 component tokens (hard rule 2 by
construction). The widget set (one renderer each):

- `record_entry` → the finding-aid card (label, claims grouped by facet, parts, verdicts)
- `provenance` → the chain (claim → visit/tier/model → audits), clickable
- `trajectory` → the deepening over time (the per-facet steps)
- `accuracy` → the audited-rate table (calibration, said out loud)
- `search` / `subject_search` → result cards
- `quote` → the located passage with the source-digest/drift flag
- `connections` → the typed-edge list

Because each renderer is a pure function of tool JSON, the **later hinge** (MCP Apps
`ui://` resources for Claude Desktop/ChatGPT) wraps the *same* renderers — the delivery
mechanism (inline SSE now vs. sandboxed iframe later) changes; the render does not.

### Per-context agents

An "agent" is config, not a framework: `{ system_prompt, tools, tier }` keyed on the active
context. Activation is a clean three-state model:

- **Nothing configured** → single-shot RAG everywhere (byte-identical; see Back-compat).
- **`config.chat_agentic = true`** → a default *general* read agent (full read toolset)
  serves root and any context without its own agent.
- **A per-context agent declared** (e.g. **chds-theses** → the *thesis-advisor* persona,
  tuned by the faculty-question eval, full read toolset, capable tier) → that context is
  agentic with its own prompt/tools/tier; contexts without one fall back to the general agent
  (if `chat_agentic`) or single-shot (if not).

This is a small extension of the existing context + staffing machinery, not a new subsystem.

## Back-compat gate (hard rule 1)

The agentic Reference Desk is **opt-in**. With no per-context agent configured and the agent
toolset empty, `/enliterator/chat` behaves **byte-identically** to today's single-shot RAG
`Conversation`. Adopting the agentic chat is a config act (`config.chat_agentic = true` or a
per-context agent declaration). The full suite stays green with it off.

## Safety — the public, accountless link

- **Read-only agent.** The public toolset excludes `propose_term` and `flag_claim`. Even
  un-authed, the Reference Desk cannot mutate the record. This is the safety argument for a
  no-login link.
- **Thesis content is public.** HSDL theses are public documents; a read-only conversational
  surface over the *enliterated thesis collection* exposes nothing governance-sensitive (the
  warehouse/alumni data the broader CHDS posture protects is not in this collection).
- **Bounded rounds.** The loop caps tool-call rounds (default 6) — cost and latency stay
  bounded regardless of question. Token budget rides the existing conversation knobs.
- **Intersection with the staging auth-wrap:** the `/enliterator` mount is auth-less in dev;
  the staging checklist wraps it. The public Reference Desk may want a *deliberately
  un-wrapped, read-only* sub-path — a governance decision flagged for Jeremy (Open Questions).

## Testing

- **Agent loop:** a stub LLM that emits scripted tool calls; assert the loop dispatches via
  `Mcp.dispatch`, feeds results back, and honors the step cap (no infinite loop).
- **Adapter `converse_with_tools`:** multi-tool-call parsing, the `tool` result role,
  streaming deltas interleaved with tool calls.
- **Widget renderers:** pure-function assertions — tool JSON → HTML containing the expected
  fields, caps respected, NO raw ids leaked (the conversation prompt rule), provenance present.
- **Per-context agent resolution:** context → `{prompt, tools, tier}`; root fallback.
- **SSE event shape:** request spec asserting the mixed stream (text + widget + status + done).
- **Back-compat:** with agentic off, byte-identical single-shot behavior (a characterization
  spec over today's `Conversation`).

Target: ~25–30 new examples; suite 537 → ~565.

## Open questions (for Jeremy)

1. **Orchestration tier.** bedrock-sonnet (capable, proven) is the safe default. The
   Codex-Spark thesis suggests a *fast* model could orchestrate *because* the tools are
   pre-calibrated and self-describing — a cheaper, snappier desk. Worth an A/B once it runs.
2. **The public-link auth posture.** Read-only + public-content argues for a no-login
   sub-path. Confirm that's the governance call, or specify a light gate.
3. **Thread persistence.** Ephemeral-per-session for the demo, or lightweight shareable
   threads (a patron sends a colleague a link to the conversation)?
4. **Widget interactivity ceiling.** v0.28 widgets are static HTML (a provenance chain you
   *read*). Click-to-drill (a chain you *expand*) is progressive enhancement — in scope or
   later?

## Staged delivery

- **v0.28 (this doc):** the branded host — agentic loop + `converse_with_tools` + the widget
  renderers + per-context agents, delivered **inline via SSE**. The reliable, accountless
  FEDLINK URL.
- **Later hinge (post-FEDLINK):** wrap the *same* widget renderers as MCP Apps `ui://`
  resources; the external-host surface (Claude Desktop/ChatGPT) renders the identical
  artifacts. Additive, not a rebuild — the whole point of the pure-renderer discipline.

## Why this is the right shape

The infrastructure *is* the argument. A Reference Desk where every answer renders its own
provenance chain — auditable, traceable, the receipts inline — demonstrates enliteracy in a
way a generic chat product cannot. The generative-UI field is racing to build UIs for
exactly this (reasoning traces, tool displays, provenance, calibration); we already produce
it as governed data. We are not behind the frontier — we are sitting on its substrate, and
the Reference Desk is how we show it through a door that needs no key.
