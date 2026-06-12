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
tier:          a gateway-advertised alias — e.g. "bedrock-haiku"/"cheap" (Frontdesk triage)
               | "bedrock-sonnet" (specialist advising). NOTE: Policy#validate! EXISTS but is
               currently never invoked (no boot hook), and it only sees the staffing policy's
               referenced_tiers (cheap/quality/embed today) — NOT the new Chat::Agent registry's
               tiers. So "wire validate!" would validate the wrong set. Agent tiers need a
               DEDICATED registration check: each agent.tier resolves to a Gateway adapter that
               `respond_to?(:converse_with_tools)` — which also confirms the gateway advertises
               the alias. A typo fails fast at boot/registration, not mid-stream. NOTE the
               bedrock-* aliases are DEPLOYMENT-PROVISIONED on the gateway (the campaign
               provisioned bedrock-sonnet/haiku), not stock intent-aliases — so the plan
               provisions them on the target gateway, or the registration check fails fast on a
               fresh install that lacks them. ("fast" is an intent alias that may be absent.)
routes_to:     [agent names]  — the Frontdesk routes to specialists
reach:         default scope = grounding context; MAY widen (see Reach)
```

- **Frontdesk** (root, no grounding context) → triage + cross-collection reasoning. Tools:
  the read tools at root scope + `route_to`. A *fast, cheap* tier — `bedrock-haiku` or `cheap`
  (routing is a quick classification). "Help me pick a thesis topic" → recognizes CHDS-Theses
  territory → hands off.
- **CHDS Theses specialist** (grounded in `chds-theses`) → deep advising. Tools: the read
  tools (default `chds-theses` scope, may widen) + the leashed web tool. *bedrock-sonnet*
  tier (advising must hold up). Persona tuned by the faculty-question eval.

**Routing/handoff** is a small mechanism we build (not a framework): `route_to(agent)` is a
capability the Frontdesk can invoke; the loop switches the active agent (persona/tools/tier/
scope) and the chat **scope banner** shows the handoff visibly ("You're now at the CHDS Theses
desk"). NOTE: the existing banner is server-rendered ERB, painted once from `current_context`
at page load — no JS touches it. So the live handoff update is **net-new client JS** (a DOM
handle + an update on the handoff event), not reuse of an existing mechanism; the plan budgets
it. Handoffs are legible and reversible (back to the Frontdesk anytime).

**Activation (back-compat).** Three states: nothing configured → today's single-shot RAG,
byte-identical; `config.chat_federation` declared → the Frontdesk + registered specialists;
a context with no specialist falls back to the Frontdesk. Hard rule 1 holds — but the gating
boundary must be the **stream event vocabulary and the view JS**, not only the agent resolver.
With no federation configured, the endpoint emits ONLY the existing event types
(`token`/`provenance`/`done`, per `conversation_controller.rb`) and the existing view JS path
runs unchanged; the new event types (`tool_call_start`, `handoff`, widget) and widget-aware JS
fire ONLY when federation is active. A new event emitted unconditionally — or new JS that
expects widgets — would break the byte-identical floor even with federation off, which is
exactly the leaky-additive seam rule 1 exists to catch.

### The reach abstraction

A specialist is **grounded, not walled.** Reach is an abstraction over resource tiers, in
library terms:

1. **Home collection** (grounding context) — the default scope, the persona's ground truth.
2. **Sister collections** (other HSDL contexts) — nearly free: the v0.26 tools take an optional
   `context` arg, so reaching `crs-reports` / `executive-orders` is just the model supplying a
   scope. The only new code is the loop's **grounding rule** (see the loop) that defaults the
   desk's own scope when the model omits one.
3. **Partner institutions** (sibling *enliterations* — Pulse) — *horizon.* When Pulse is
   enliterated it exposes the *same* v0.26 MCP surface; the Frontdesk routes to it as another
   node. **The MCP surface we shipped is the federation protocol.**
4. **The open literature** (the web) — *leashed/labeled, specialist-only* (below). The
   Frontdesk does not hold the web tool; only a grounded specialist does.

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
    model(messages, active.tools + route_to)   # route_to schema injected here, NOT from Mcp.listing
      ├─ route_to(specialist) → switch active (persona/tools/tier/scope), announce, continue
      │                          (intercepted in the loop — never reaches Mcp.dispatch)
      ├─ tool_call(s)         → ENFORCE active.tools allow-list → Mcp.dispatch
      │                          → widget + tool-result (fed back)  |  raise → tool_call_error event
      └─ final answer         → DONE
  cap reached without a final answer → visible "step budget" message + log (never a silent cut)
```

- **Tools = REUSE the schema, with the LOOP as the enforcement boundary.** `Mcp.listing`
  (name/description/inputSchema → function defs) + `Mcp.dispatch(name, args)` as executor; the
  chat agent and the external MCP server share ONE tool *schema*. But `Mcp.dispatch` resolves
  the name against the FULL `tool_classes` list (no subset notion) and `validate!` rejects
  unknown keys (`mcp.rb`). So three things the LOOP owns, never the model:
  1. **Allow-list before dispatch (where read-only becomes REAL).** The agent's advertised
     `tools` array controls only what the model is *offered* — read-only is NOT enforced by
     omission. An injected instruction in fetched web content could emit a
     `flag_claim`/`propose_term` call by name, and `Mcp.dispatch` would execute it. The loop
     MUST validate every tool name against the active agent's allow-list BEFORE dispatch. That
     is the read-only enforcement boundary, on exactly the injection surface Safety worries
     about — advisory omission is not enforcement. ORDERING (matters): intercept `route_to`
     FIRST (it is not in any agent's `tools`, so the allow-list would wrongly reject it), THEN
     allow-list the remaining tool names. Backwards, routing silently breaks.
  2. **Grounding rule — context-bearing tools ONLY.** Inject the desk's context into a call's
     args only when the model *omits* `context` AND the tool's `input_schema` declares a
     `context` property. Several tools (`provenance`, `quote`, `accuracy`) take NO `context`;
     injecting it trips `validate!`'s unknown-key rejection and breaks the cheapest, most-used
     tools. Model-supplies → honor (the "not walled" widen); model-omits on a context-bearing
     tool → desk default; tool has no `context` → inject nothing. (On the public desk this only
     ever touches read tools. On the authed surface, which offers governed writes, the same rule
     auto-scopes `propose_term` — which IS context-bearing — to the active desk's context: the
     intended behavior, a suggestion filed against the desk you're working in.)
  3. **Affordance filter — model-facing, recursive, prefix-keyed.** Internal paths are
     pervasive and nested at varying depths: `entry: "/enliterator/status/…"` on every record
     block (`tool.rb`), and `next: { human_view: "/enliterator/{review,suggestions,settings,
     status} }` across `accuracy`/`collection_overview`/`vocabulary`/etc. These live in the
     tool-result JSON the MODEL consumes, so hiding them in the widget is not enough — the model
     could echo `/enliterator/review` into its prose. The public desk runs a **recursive scrub
     keyed on the `/enliterator/` prefix** (not a top-level field allowlist, which misses the
     nested `next:` hints) over tool results BEFORE they reach the model and the widget; the
     allow-list (1) makes write surfaces uncallable regardless. The scrub is **surface-conditional
     and UPSTREAM of the shared renderer**: on the authed in-app surface those deep-links are
     desirable (they send a logged-in curator to `/review`), so authed does NOT scrub; public
     does. Applying it upstream — per surface, before the shared `Chat::Widget` runs — keeps the
     renderer a PURE function over already-surface-appropriate JSON (no `surface` branch inside
     the renderer).
- **`route_to` is a loop pseudo-tool, not an MCP tool.** Its function schema is assembled into
  the tools array OUTSIDE `Mcp.listing` (which returns only the 14 registered tools) and
  intercepted in the loop BEFORE `Mcp.dispatch` (which would raise `unknown tool`). It switches
  the active agent; it is never dispatched. Injected ONLY for agents with a non-empty
  `routes_to` (a grounded specialist with no routes never sees it); a `route_to` emitted by an
  agent that wasn't offered it (hallucinated or injected) is a visible `tool_call_error`, not a
  silent no-op — and its name must not collide with any of the 14 registered tools.
- **Step cap + direct-answer bias** keep it economical — multi-hop only when the question
  demands it.
- **A tool failing mid-loop is a VISIBLE failed-tool event (rule 3) — but not every tool
  RAISES, and "empty" is ambiguous.** `search` raises on a degraded embedder (it calls the live
  embedder); `Atlas.build` failing raises. The stream vocabulary carries a `tool_call_error`
  event the patron sees ("couldn't consult X"), the loop logs it, and the model is told. The
  subtler trap is `connections`, which does NOT call the live embedder at query time — it reads
  the record's *stored* primary embedding (`connections.rb`) and returns `[]` neighbors when the
  record was never embedded, and `[]` edges when the record isn't in the cached Atlas. Both
  empties are indistinguishable to the model from "genuinely none." So the gap is a LABELING gap,
  not an embedder-down detection: `connections` must distinguish "no connections (real)" from
  "this record has no stored embedding / isn't in the atlas yet" in its result, so the
  widget/model can say which. (General audit: any tool that degrades to a bare `[]` rather than
  raising needs its empties labeled before it enters the loop — but verify each tool's ACTUAL
  degradation path; they differ.)
- **Tool cost is asymmetric — and only `connections` is cached.** `provenance`/`quote` are
  cheap reads. `connections` builds the Atlas, which rides the v0.20 cache (`Atlas.build` →
  `Rails.cache`, keyed by latest heartbeat id), so repeats are cheap *given a durable store*.
  `accuracy` is NOT cached: `Audit.accuracy` + `anchor_agreement` load the full instrument
  audit set and aggregate in Ruby on EVERY call, growing with the set — and `collection_overview`
  (the "call this first" tool) runs `Audit.accuracy` INLINE, so that uncached aggregate fires on
  the FIRST turn of every conversation. RESOLVED, not deferred (it's the single most-certain
  per-conversation cost on the reliability-critical public path): cache `Audit.accuracy` /
  `anchor_agreement` in `Rails.cache` — but NOT on the bare latest-heartbeat-id key the other
  rollups use. Accuracy has out-of-band write paths the others don't: audits are filed by the
  heartbeat (examiner) AND by humans on `/review` AND by agents via `flag_claim`, *between*
  beats. A heartbeat-id-only key would serve a stale number after a human anchors a verdict until
  the next beat (silently diverging from `/review`). Key it on something that also moves on those
  writes — `max(audits.updated_at)` or the audit count — or accept a short TTL and state the
  staleness bound. With that, the overview roll-up and the `accuracy` tool both serve from cache
  (as `connections` already does), and all three share ONE durable-store requirement with the
  rate limiter (Safety). The only open question left is whether `connections` stays in the
  DEFAULT loop toolset — not whether the aggregates are cached (they are). One parallel
  cold-cache caveat: `connections`'s first call after a deploy or after the heartbeat-id key
  rolls pays a full `Atlas.assemble` (~18s, the v0.20 measure) before the cache fills — a
  first-turn latency on the public path of the same character as the accuracy one. `Atlas.build`
  caches PER CONTEXT (its key includes `context&.key || "root"`) and `connections` passes the
  active desk's grounding context, so warm once PER GROUNDED CONTEXT (root for the Frontdesk +
  each specialist's context) — a single root assemble never fills the `chds-theses` key the
  specialist actually hits. Or state the per-context cold-cache bound; don't leave the first
  patron after a deploy waiting 18s.
- **Wall-clock budget, not just a step cap — the most likely "doesn't hold up live" failure.**
  The step cap bounds ROUND-TRIPS (4), not latency: at the gateway's 180s timeout × up to 4
  rounds, worst case is ~12 minutes before anything terminal reaches the patron. The loop
  carries a per-TURN wall-clock budget (e.g. 60–90s) distinct from the step cap; exceeding it
  emits a visible terminal event and stops. Enforcement matters: a between-round elapsed-time
  check cannot interrupt a SINGLE in-flight `converse_with_tools` call, which can block up to the
  gateway's 180s `gateway_timeout` (a GLOBAL config, `lib/enliterator.rb`) before the loop
  regains control — so the budget needs a SHORTER per-call timeout on the public desk's adapter
  (a per-surface gateway timeout, e.g. 30s), not just cooperative between-round checks. The plan
  pins the per-call timeout and the turn budget together. And a gateway/adapter raise
  mid-`converse_with_tools` (timeout/5xx) surfaces as a visible terminal event (rule 3) — not a
  bare bubble to the controller's generic `:error` after widgets have already streamed.
- **Cap-exhausted is a VISIBLE outcome, not a silent truncation (rule 3).** If the cap is
  reached without a final answer, the desk emits an explicit "I reached my step budget — here's
  what I have so far" message and logs the event (which tools ran, why it stopped) — never a
  silently cut stream. Tested distinctly from the bound: the bound test asserts no infinite
  loop; the degraded-answer test asserts the visible cap-exhausted message.

### Adapter: `converse_with_tools` (NEW plumbing on the existing tool transport)

The genuinely new primitive — and bigger than "generalize two parse helpers," so the plan
must budget it honestly. Today `decide` *forces* one tool and returns its parsed args
(`gateway.rb`); `converse` streams text with no tools. Neither emits `tool_choice: auto`,
returns assistant `tool_calls` for feedback, or builds the `{role: "tool", tool_call_id:,
content:}` messages a loop must append. The new call must: (a) pass the full tools array with
`tool_choice: auto`; (b) extract **all** tool calls plus their ids from a response (the
existing `first_tool_call` reads only the first); (c) re-serialize the assistant turn carrying
its `tool_calls`; (d) build tool-result messages keyed by `tool_call_id`; (e) interleave that
round-trip with streamed text deltas. What is PROVEN is forced-*single*-tool through the
gateway (Bedrock Converse translates `tool_choice`); optional-multi-tool with results fed back
and streamed is new. It reuses the JSON-extraction helpers (`arguments_of`), not the control
flow.

**Adapter resolution is GATEWAY-ONLY — pin it, guard it.** The loop resolves a per-agent
adapter via `Enliterator.llm(tier: active.tier)`, rebuilt on every handoff (not the existing
single-adapter `Conversation#resolve_llm`). Critically, `converse_with_tools` is built on
`converse`, and ONLY the `Gateway` adapter implements `converse`/`decide` — the *direct*
`Bedrock` adapter (the documented `config.llm_adapter = Bedrock.new` path) implements only
`tend` and inherits `converse`/`decide` from `Base` as `NotImplementedError` raisers. A
federation wired to a directly-configured Bedrock adapter would 500 mid-stream. Precondition:
`Enliterator.llm(tier:)` yields a Gateway ONLY when `gateway_api_key` is present; absent it,
the engine returns `config.llm_adapter` (possibly the direct Bedrock) or Null — which is
exactly why the `respond_to?(:converse_with_tools)` registration guard is **load-bearing, not
redundant**. So: require the gateway key, agents resolve through `Enliterator.llm(tier:)`, and
registration refuses any agent whose resolved adapter lacks `converse_with_tools` — a named
boot/registration failure, not a mid-stream `NotImplementedError`.

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

### Transport — TWO controllers, one shared loop

The agentic loop + widget renderers are a shared SERVICE layer (`Conversation::Agent`,
`Chat::Widget`). Two controllers drive it, because the authed and public surfaces have
incompatible postures and the byte-identical floor and the no-cookie requirement collide on a
single endpoint:

- **Authed in-app chat (EXTEND `conversation_controller#stream`).** Keeps Rails forgery
  protection and `current_context` (cookie-writing is fine for an authed in-app session).
  Federation is gated: with `config.chat_federation` off, this action is byte-identical (see
  Activation). This is the surface hard rule 1 protects.
- **Public desk (NET-NEW controller + route).** Sessionless, `skip_forgery_protection`,
  server-side scope (no `current_context`, no cookie), token + rate-limit. Because it didn't
  exist before, byte-identical is trivially satisfied — there is no old behavior to preserve.
  This cleanly honors BOTH the no-cookie requirement and rule 1: the existing
  `conversation#stream` is literally untouched on the no-federation path, and the public desk
  is new.

**One wire vocabulary, not two.** The existing stream emits lowercase `token`/`provenance`/
`done` and the client branches on `token`/`provenance`/`error`; the federation stream KEEPS
those exact events (so the no-federation authed path is byte-identical) and ADDS new ones in the
same lowercase convention — `tool_call_start`, `tool_call_result` (widget), `tool_call_error`,
`handoff`. We borrow AG-UI's *semantics* (typed execution events), NOT its casing — no
`TEXT_MESSAGE_CONTENT`/`DONE` rename of existing events. Map: `token`/`provenance`/`done`→kept;
added → `tool_call_start`/`tool_call_result`/`tool_call_error`/`handoff` (emitted only when
federation is active).

**The view ships widget JS only under a server-rendered federation flag.** The client is a
statically-served page; it cannot conditionally ship two JS bodies per request unless the
controller branches the view. So the authed chat view emits the widget-aware JS only inside a
federation-gated server-rendered branch (the no-federation view file is byte-identical); the
public desk has its OWN view (always widget-aware). The existing `handleFrame` silently drops
unknown events (no `else`) — a helpful safety net, but the byte-identical guarantee rests on the
gated view branch, not on the client tolerating stray events. The frontend (vanilla JS, hard
rule 2) appends widgets and updates the scope banner on `handoff`.

## Safety — the public, accountless link

The public desk is a **separate entry point** from the in-app authed chat, with its own
controller posture. The in-app `/enliterator/chat` keeps Rails forgery protection (its JS
sends the session CSRF token, as today). The public desk is sessionless, which forces
decisions the auth label alone hides:

- **CSRF posture (resolved, not assumed).** A genuinely accountless link has no session, so
  the session-derived CSRF token the current chat relies on doesn't exist. The public stream
  endpoint therefore uses `skip_forgery_protection` (as `mcp_controller.rb` already does) —
  justified because it is sessionless AND read-only AND rate-limited: CSRF protects an
  *authenticated* user from unwanted *state-changing* actions; with no session and no writes,
  it is not the relevant control. The compensating controls are the link token + rate limit +
  read-only toolset. (A POST `ActionController::Live` stream under skip_forgery, or a GET
  EventSource — the plan picks one, but not symmetrically: the existing client already
  POST-streams via `fetch`+`getReader`, so POST-under-skip_forgery reuses its shape, while a GET
  `EventSource` is a second divergent client AND cannot send custom headers — which would force
  the link token into the URL rather than a header. The existing code leans POST.)

- **Scope resolution must not ride the cookie path.** `ApplicationController#current_context`
  reads `params`/`cookies` AND **writes** `cookies[CONTEXT_COOKIE]` on every resolve, and the
  current `ConversationController#stream` calls it. A "sessionless" public desk that inherited
  that path would set cookies and **bleed scope across patrons sharing one link**. The public
  desk resolves the active desk's scope SERVER-SIDE from the agent's grounding context,
  ignoring `current_context` and the cookie entirely; its controller does not inherit the
  cookie-writing `resolve_context`. **This and the loop's grounding rule are ONE path, not
  two:** the specialist's scope reaches the tools only through the grounding-rule injection. If
  that injection is incomplete, a public specialist silently answers at *root* scope — a reach
  leak (cross-collection), distinct from but as bad as cookie bleed. Specify and test the two
  together, not as independent mitigations. *Mechanism (the leak path is the LAYOUT, not the
  action):* `current_context` is a `helper_method`, so any stray call in a shared layout/partial
  the public view renders would write the cookie even if the action never calls it. The public
  controller therefore OVERRIDES `current_context` to return the server-resolved grounding scope
  and never touch cookies; the request spec asserts **no `Set-Cookie` on the full rendered
  response** (layout included), not merely that the action skipped it.

- **(b) Accountless but lightly protected — and the controls must be REAL, not named.** A
  safety control backed by nothing is worse than none, because it *reads* as protected:
  - *Link token:* a high-entropy token in the link, checked before the loop runs; unknown or
    absent → 404 (never a hint that a valid token exists). Validation needs a SOURCE OF TRUTH —
    specify it, don't leave it a single hardcoded constant (no revocation) or a silently-absent
    check: either a small DB table of issued tokens (mint + revoke rows, optional expiry) or a
    signed/HMAC token verified statelessly (revocation via a key/epoch bump). The plan picks one
    and specs that a forged-but-well-formed token 404s.
  - *Rate limit:* keyed on the link token + client IP — **not** "per-session," there is no
    session. Rails 8 `ActionController::RateLimiting` needs a cache store, but "has a store" is
    not enough: test defaults to `:null_store`, and dev/prod default to per-process
    `:memory_store` (the engine's production `config.cache_store` is commented out). A
    `:null_store` is a silent no-op. A per-process `:memory_store` is subtler and worse — it
    READS FINE, so a naive "can I reach the store?" guard passes, yet every Puma worker keeps
    its OWN counter (effective limit = N×workers, reset on deploy). The control must assert a
    **shared, persistent** store (Solid Cache / Redis / memcached), and the public desk must
    **refuse to ACTIVATE (serve)** on a `:null_store`/`:memory_store` backend — scoped to the
    public-desk config path, NOT an engine-boot refusal. (The engine's own suite runs
    `:null_store`/`:memory_store`, and a boot refusal would break rule 1's suite-green discipline
    and every default host; an engine with no public desk configured boots normally and is
    byte-identical. Only *serving the public link* requires the durable store.) A safety control
    that silently under-counts is the rule-3 failure that matters most. *Live interaction:* the
    limit is a `before_action` returning a plain **429 before `ActionController::Live` opens the
    stream** — a `head :too_many_requests` AFTER `response.stream` is committed raises
    `DoubleRenderError`. A rate-limited patron gets a clean 429, not a mid-stream event. And
    because `ActionController::Live` runs the body in a separate thread that does NOT run
    `rescue_from` the normal way, the plan specs that (a) a rate-limited request returns a clean
    429 with NO partial stream opened, and (b) an exception inside the live thread (a gateway
    raise mid-loop) closes the stream DETERMINISTICALLY (visible terminal event + `ensure`
    close), never hanging the connection.

- **Read-only.** No `propose_term`/`flag_claim` in any public toolset; the desk cannot mutate
  the record. This caps the blast radius of *anything* that goes wrong — including injection,
  below — at READS.

- **Web content is UNTRUSTED INPUT, not just a citation to separate.** The output invariant
  (collection vs web never blend) is necessary but NOT sufficient. Web text fetched into a
  tool-bearing loop is the classic prompt-injection→tool-use vector: a fetched page can try to
  steer the agent's *next* tool calls (scope-widening via the `context` arg, further web
  fetches). Layered mitigations: (1) web results enter the context **delimited and labeled as
  untrusted external data that is never to be treated as instructions** (the
  instruction-source-boundary discipline); (2) the read-only toolset caps blast radius at
  reads; (3) the step cap bounds how far an injected instruction can run; (4) the agent prompt
  forbids acting on instructions found in fetched content. The Safety story is
  web-as-instruction, not only web-as-source.

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
- **The loop's enforcement boundary (the safety-critical specs):**
  - *Allow-list before dispatch:* a stub LLM emitting a `flag_claim`/`propose_term` call (the
    injection case) is REFUSED by the loop before `Mcp.dispatch` runs — read-only is enforced,
    not advisory.
  - *Grounding rule:* context injected only when the model omits it AND the tool declares a
    `context` property; a `provenance`/`quote` call (no `context`) is dispatched unmodified
    (no `validate!` unknown-key raise); a `search` call with no `context` gets the desk default;
    a `search` call WITH a `context` is honored (the widen).
  - *`route_to` interception:* `route_to` switches the agent and never reaches `Mcp.dispatch`.
- **Cap-exhausted + failed-tool (rule 3):** cap reached without a final answer emits the
  visible "step budget" message + logs; a tool that raises mid-loop emits `tool_call_error`
  (the patron sees it) and the model is told, rather than a silently shorter answer.
- **`converse_with_tools`:** multi-tool parsing (ALL calls + ids, not just the first), the
  `tool` result role keyed by `tool_call_id`, streamed deltas interleaved with tool calls.
- **Widget renderers:** pure-function assertions — tool JSON → HTML with expected fields,
  caps respected, no raw ids leaked, provenance present; the web-supplement widget is
  visually/structurally distinct (the separation invariant, spec-pinned); internal
  `/enliterator/…` paths stripped from public tool results (model-facing, not just the widget).
- **Agent resolution + activation:** context → agent; Frontdesk fallback; back-compat
  byte-identical with no federation configured (the stream emits only `token`/`provenance`/
  `done`, old JS path unchanged).
- **Public-desk posture:** scope resolves server-side from the grounding context, writing NO
  cookie (no cross-patron bleed); the desk refuses to boot on a `:null_store`/`:memory_store`
  rate-limit backend.
- **SSE event shape:** request spec over the mixed stream (text + widget + status + handoff +
  error + done).
- **Live browser verification:** drive the **public desk URL** (the accountless token link —
  the surface the FEDLINK "holds up live" constraint is actually about), NOT the authed
  `/enliterator/chat`, via chrome-devtools-mcp — assert widgets render, a handoff updates the
  banner, a provenance widget shows its chain, and the sessionless posture holds (no cookie
  written). The authed chat is covered by request/unit specs; the live check targets the surface
  that must hold up in the room.

Target is a floor, not a ceiling: ≈ 40+ new examples (the enumerated groups — multi-tool
parse, the enforcement-boundary specs, the mixed-stream request spec, 8+ widget renderers with
multiple assertions each, live browser verification — plausibly exceed 40 on their own; the
plan re-derives bottom-up). Suite 537 → 580+ (537 is v0.27 head — re-confirm green before
baselining).

## Decisions (resolved in review, 2026-06-12)

| # | Question | Decision |
|---|---|---|
| 1 | How agentic? | **Governed loop** (step cap + direct-answer bias); routing gives it legible purpose. Single-shot is the back-compat floor. |
| — | Per-context agents | **Reframed to a federation**: Frontdesk (triage/route) + grounded-not-walled specialists. |
| 2 | Public-link auth | **(b)** accountless + unguessable token + rate limit. Minimal friction. |
| — | Web access | **(b)** in but leashed/labeled; provenance-separation invariant. |
| 3 | Thread persistence | **Ephemeral** now; modeled as attributable turns. Shared + collaborative is a firm horizon requirement. |
| 4 | Orchestration tier | **Per-agent**: Frontdesk fast/cheap (bedrock-haiku or cheap), specialist sonnet. Gateway-advertised aliases only — validated by a DEDICATED agent-registration check (`respond_to?(:converse_with_tools)`), NOT `Policy#validate!` (which sees the staffing policy's tiers, not the agent registry). Empirically tunable. |
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
