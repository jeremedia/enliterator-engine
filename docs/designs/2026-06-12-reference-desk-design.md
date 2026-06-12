# v0.28 — The Reference Desk (the conversational surface, made agentic)

*Design doc — 2026-06-12. Status: **FINALIZED** (reviewed with Jeremy). Gated on plan
approval before code.*

## Context

The engine's Chat surface (`/enliterator/chat`) is today a single-shot reference interview:
embed the question, retrieve 5 records, answer in prose with source chips
(`Enliterator::Conversation`). It works, but it does not *use* the v0.26 MCP surface — the 14
tools that give an agent calibrated, provenance-bearing hands on the collection.

This upgrades Chat into **the Reference Desk**: a patron arrives at a **Frontdesk** that
reasons across the whole HSDL federation and *routes* them to a **specialist desk** (CHDS
Theses) when the question is squarely in its domain. The specialist is *grounded* in its
context's particulars but not *walled* into them — it can reach across sibling collections
and, leashed, to the open web. Every answer arrives as prose interleaved with **inline
widgets** rendering the actual record cards, provenance chains, and trajectory the agent
consulted. This is the Knowledge Navigator pattern, grounded in governed provenance.

**Product constraint (Jeremy):** a URL handed to CHDS staff and the FEDLINK audience that
works in any browser with **no account and no install**, with **as little friction as
possible** in early phases, and that we *know* holds up live. **Deadline:** FEDLINK (Library
of Congress), 2026-07-14.

## The design spine: foundation-shaped subsets

Every v0.28 component is the **foundation-shaped subset of its eventual full form** — never a
throwaway, never something that has to be torn out to grow. This is the organizing
discipline, and it recurs four times:

| Component | v0.28 (foundation) | Horizon (additive, no rework) |
|---|---|---|
| **Widget** | inline-rendered HTML | wrapped as MCP Apps `ui://` for external hosts |
| **Reach** | home context + sibling contexts | sibling *enliterations* (Pulse) + full web |
| **Thread** | ephemeral, attributable turns | persistent + multi-participant (student+advisor) |
| **Web** | the leashed/labeled contract, lightly wired | full open-literature reach |

We build nothing for July 14 that fights the horizon. The foundation ships; the federation is
the horizon we don't block.

## Goals

1. **A federation of agents** mirroring the federation of contexts: a Frontdesk that triages
   and routes, specialists grounded in their context's particulars.
2. **Agentic, governed.** The agent reasons across multiple tool calls (route → ground →
   `record_entry` → `provenance` → `quote`) under a tight step cap and a prompt biased toward
   answering directly when one retrieval suffices. Purposeful (routing/grounding), not
   open-ended thrashing.
3. **Inline widgets** rendering the collection's unique substrate — provenance, trajectory,
   accuracy — as self-contained HTML.
4. **A public, accountless, low-friction, reliable URL.** The branded host *is* the demo.
5. **Build every component as a foundation-shaped subset** (see the spine).

## Non-goals (YAGNI) — deferred, but *designed for*

- **The full federation.** v0.28 ships Frontdesk + the CHDS Theses specialist *within HSDL*.
  Sibling enliterations (Pulse) are a horizon node — reachable later via the *same* v0.26 MCP
  protocol with no new plumbing.
- **Full web reach.** The leashed/labeled contract is built; broad web wiring is later.
- **Persistent / collaborative threads.** Modeled-for (attributable turns + thread identity),
  not built.
- **MCP Apps external-host rendering.** The widget renderers are pure functions ready to wrap
  as `ui://`; the wrapping is later.
- **Adopting RubyLLM / AG-UI / ChatKit SDKs.** We borrow AG-UI's *event vocabulary* and MCP
  Apps' *widget shape*; we keep our own LLM adapter + staffing spine — that spine is the
  provenance argument.
- **Governed writes in the public agent.** `propose_term` / `flag_claim` are excluded from
  every public toolset (read-only public desk).

## Architecture

### The agent federation

An **agent** is a registered definition, not a framework — `Enliterator::Chat::Agent`:

```
name:          "CHDS Theses"
grounding:     context key ("chds-theses"); nil grounding = the Frontdesk (root)
system_prompt: persona + grounding facts (faculty-eval-informed; see Grounding)
tools:         the read-tool subset (+ web for specialists; NEVER propose/flag in public)
tier:          "fast" (Frontdesk triage) | "bedrock-sonnet" (specialist advising)
routes_to:     [agent names]  — the Frontdesk routes to specialists
reach:         default scope = grounding context; MAY widen (see Reach)
```

- **Frontdesk** (root, no grounding context) → triage + cross-collection reasoning. Tools:
  the read tools at root scope + `route_to`. *Fast* tier (routing is a quick classification).
  "Help me pick a thesis topic" → recognizes CHDS-Theses territory → hands off.
- **CHDS Theses specialist** (grounded in `chds-theses`) → deep advising. Tools: the read
  tools (default `chds-theses` scope, may widen) + the leashed web tool. *bedrock-sonnet*
  tier (advising must hold up). Persona tuned by the faculty-question eval.

**Routing/handoff** is a small mechanism we build (not a framework): `route_to(agent)` is a
capability the Frontdesk can invoke; the loop switches the active agent (persona/tools/tier/
scope) and the existing chat **scope banner** renders the handoff visibly ("You're now at the
CHDS Theses desk"). Handoffs are legible and reversible (back to the Frontdesk anytime).

**Activation (back-compat).** Three states: nothing configured → today's single-shot RAG,
byte-identical; `config.chat_federation` declared → the Frontdesk + registered specialists;
a context with no specialist falls back to the Frontdesk. Hard rule 1 holds: with no
federation configured, `/enliterator/chat` is unchanged.

### The reach abstraction

A specialist is **grounded, not walled.** Reach is an abstraction over resource tiers, in
library terms:

1. **Home collection** (grounding context) — the default scope, the persona's ground truth.
2. **Sister collections** (other HSDL contexts) — **already free**: the v0.26 tools take an
   optional `context` arg, so the CHDS agent reaches `crs-reports` / `executive-orders` by
   passing a different scope. No new code.
3. **Partner institutions** (sibling *enliterations* — Pulse) — *horizon.* When Pulse is
   enliterated it exposes the *same* v0.26 MCP surface; the Frontdesk routes to it as another
   node. **The MCP surface we shipped is the federation protocol.**
4. **The open literature** (the web) — *leashed/labeled* (below).

### The web tool + the provenance-separation invariant

Web reach is decision **(b): in, but leashed.** The structural invariant — encoded from the
first line, not a disclaimer:

> **A collection claim and a web supplement never blend in one assertion.** Web content is
> always labeled as web, cited separately, and visually distinct in its widget.

That line is the differentiator. The web tool (`web_search` / `web_fetch`, source TBD in the
plan) is available only to specialists, its results render in a *visually distinct
"supplement" widget*, and the agent prompt forbids merging web facts into collection claims.
Public-link safety (below) bounds its use.

### The agentic loop

`Enliterator::Chat::Agent` (loop) drives model↔tools rounds for one turn:

```
turn → active = Frontdesk
  loop (step cap, default 4):
    model(messages, active.tools + route_to)
      ├─ route_to(specialist) → switch active (persona/tools/tier/scope), announce, continue
      ├─ tool_call(s)         → Mcp.dispatch → widget + tool-result message (fed back)
      └─ final answer         → DONE
```

- **Tools = REUSE.** `Mcp.listing` (name/description/inputSchema → function defs) +
  `Mcp.dispatch(name, args)` as executor. The chat agent and the external MCP server share
  ONE tool definition.
- **Step cap + direct-answer bias** keep it economical — multi-hop only when the question
  demands it.

### Adapter: `converse_with_tools` (EXTEND)

The missing primitive. The gateway adapter does forced-single-tool (`decide`) and no-tool
(`converse`); this adds optional-multi-tool with the `tool` result role fed back. The parsing
helpers (`first_tool_call`, `arguments_of`) exist; we generalize from one forced call to N
optional calls. We proved `tool_choice → Converse` works through the gateway with Bedrock.

### The widget renderers (NEW)

`Enliterator::Chat::Widget` — pure functions `(tool_name, result_json) → HTML`, one per
widget-worthy tool (`record_entry`, `provenance`, `trajectory`, `accuracy`, `search`,
`subject_search`, `quote`, `connections`) plus the distinct **web-supplement** widget. Built
on the v0.19 component tokens — inline, no CDN (hard rule 2 by construction). **Static HTML;
click-to-drill is progressive enhancement** (the static render is the content; interactivity
is additive JS that changes nothing underneath). Because each renderer is a pure function,
the later MCP Apps `ui://` wrapping reuses it verbatim.

### The thread model (NEW, foundation-shaped)

Even ephemeral, a conversation is modeled as a **thread of attributable turns** — a thread
identity + turns stamped with author (`patron` / agent-name) and the active desk. v0.28 holds
this in the session only (no table). Making it persistent + multi-participant later (the firm
future requirement: student + advisor in one thread) is *save the thread + add participants* —
never a teardown.

### Transport (EXTEND)

`conversation_controller#stream` drives the loop and streams a mixed event stream — text
deltas, tool-status pills, widget blocks, handoff announcements — with event shapes borrowed
from AG-UI (`TEXT_MESSAGE_CONTENT`, `TOOL_CALL_START`, `TOOL_CALL_RESULT`, a handoff event,
`DONE`). The frontend (vanilla JS, hard rule 2) appends widgets and updates the scope banner
on handoff.

## Safety — the public, accountless link

- **(b) Accountless but lightly protected.** An unguessable link token + per-session rate
  limit, atop the step cap. Zero account, zero login, no captcha/email/consent — friction
  floor only against abuse (a public agent with web + LLM reach is otherwise an open proxy).
- **Read-only.** No `propose_term`/`flag_claim` in any public toolset; the desk cannot mutate
  the record.
- **Web leashed.** Supplement-only, labeled, separated; bounded by the rate limit and step
  cap.
- **Public content.** HSDL theses are public documents; the read-only desk over the
  enliterated thesis collection exposes nothing governance-sensitive.

## Grounding the specialist (the hallucination guard)

"Grounded in CHDS's programs" via a hand-authored prompt alone is a hallucination risk. v0.28
grounds the CHDS specialist in a small **authored "CHDS program facts" resource**
(faculty-eval-informed), not free-form prompt assertions. Horizon: the program's own docs
(curriculum, thesis handbook) become an enliterated context — the advisor grounded in an
enliterated context *about* the program.

## Testing

- **Agent loop + routing:** stub LLM emitting scripted tool/route calls; assert dispatch via
  `Mcp.dispatch`, handoff switches the active agent, the step cap holds (no infinite loop).
- **`converse_with_tools`:** multi-tool parsing, the `tool` result role, streamed deltas
  interleaved with tool calls.
- **Widget renderers:** pure-function assertions — tool JSON → HTML with expected fields,
  caps respected, no raw ids leaked, provenance present; the web-supplement widget is
  visually/structurally distinct (the separation invariant, spec-pinned).
- **Agent resolution + activation:** context → agent; Frontdesk fallback; back-compat
  byte-identical with no federation configured.
- **SSE event shape:** request spec over the mixed stream (text + widget + status + handoff +
  done).
- **Live browser verification:** drive `/enliterator/chat` via chrome-devtools-mcp — assert
  widgets render, a handoff updates the banner, a provenance widget shows its chain.

Target ≈ 40 new examples; suite 537 → ~577.

## Decisions (resolved in review, 2026-06-12)

| # | Question | Decision |
|---|---|---|
| 1 | How agentic? | **Governed loop** (step cap + direct-answer bias); routing gives it legible purpose. Single-shot is the back-compat floor. |
| — | Per-context agents | **Reframed to a federation**: Frontdesk (triage/route) + grounded-not-walled specialists. |
| 2 | Public-link auth | **(b)** accountless + unguessable token + rate limit. Minimal friction. |
| — | Web access | **(b)** in but leashed/labeled; provenance-separation invariant. |
| 3 | Thread persistence | **Ephemeral** now; modeled as attributable turns. Shared + collaborative is a firm horizon requirement. |
| 4 | Orchestration tier | **Per-agent**: Frontdesk fast, specialist sonnet. Empirically tunable. |
| 5 | Widget interactivity | **Static HTML**; click-to-drill is progressive enhancement. |

## Staged delivery

- **v0.28 (this doc):** the branded host — the federation (Frontdesk + CHDS Theses specialist
  within HSDL), governed agentic loop, `converse_with_tools`, the widget renderers, the
  leashed-web contract, ephemeral attributable-turn threads, the (b) public link. The
  reliable, accountless, low-friction FEDLINK URL.
- **Horizon (post-FEDLINK, additive):** Pulse as federation node two; full web reach;
  persistent + collaborative threads; MCP Apps `ui://` external-host rendering; widget
  drill-down. Each slots into a foundation already shaped for it.

## Why this is the right shape

The infrastructure *is* the argument. A Reference Desk that triages you to the right
specialist, grounds you in a collection's particulars, reaches across the federation when
needed, and renders every assertion's provenance inline — auditable, separated from any web
supplement — demonstrates enliteracy in a way no generic chat product can. The generative-UI
field is racing to build UIs for exactly this substrate (reasoning traces, tool displays,
provenance, calibration); we already produce it as governed data. We are not behind the
frontier — we are sitting on it, and the Reference Desk shows it through a door that needs no
key.
