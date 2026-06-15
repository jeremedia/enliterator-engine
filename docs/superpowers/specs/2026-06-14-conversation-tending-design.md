# Conversation-Tending — Design (v0.42)

**Goal:** Tend the retained chat turns (v0.39) along **conversation-quality facets** so the desk's
own conversational ability becomes *measured* and *compounding* — the engine turning its tending on
the one surface where it speaks. v2 is the **measurement foundation**: judge each turn, roll up to a
per-desk scorecard. Feeding quality back into persona/register editing is **v3** (named, designed-for,
not built here).

**Status:** Approved design (brainstorm 2026-06-14). Next: implementation plan → subagent-driven build.

## The elegant core

Two facts make this almost pure reuse:

1. **`Chat::Turn` becomes a `Tendable`** — exactly the v0.25 `Part` move. Including `Enliterator::Tendable`
   gives a turn the whole loop (visits, claims, reconciliation, escalation, measures, audit grounding)
   polymorphically, and the registration rule auto-skips any `Enliterator::*` class, so tended turns
   never enter planner root lanes, the corpus census, or the condition survey. **No new tables** — the
   judgments hang on the existing polymorphic `enliterator_claims` / `enliterator_visits` /
   `enliterator_measures`.

2. **The `events` jsonb already holds the turn's action sequence.** A turn is a **move** composed of
   zero-or-more **actions** (input → think → use tools → consider results → select output → render),
   and the Loop already recorded those actions in `events` (tool_call_*, handoff, the emitted output).
   So the move/action decomposition exists in the data; we judge over it, we don't invent it.

And the thesis holds even though a turn is **frozen**: re-tending doesn't re-read a changed record, it
**re-judges with a better judge** — a stronger model or sharper rubric *supersedes* an earlier verdict
via ordinary reconciliation. The turn never changes; the judgment compounds. The recursion, real.

## Decisions (from the brainstorm)

- **Primary payoff:** quality *measurement* (the smallest honest v2 that proves the recursion and
  yields a real instrument). Feedback-into-personas = v3.
- **Rubric:** **4 judged facets** (`turn_grounded`, `turn_answered`, `turn_register`, `turn_move`)
  **+ 1 computed measure** (`tool_efficiency`). Don't pay a model to count tool calls.
- **The move/action model:** `turn_move` is the *judged whole* (was this the right move?); the
  constituent actions are the `events`; `tool_efficiency` is the *computed* read over the same action
  sequence (economy). Per-action first-class tending (the `Part` pattern one level deeper) is the named
  future, not v2.
- **Invocation:** deliberate-first — a service + rake over untended turns, facets `scheduled: false`
  (the v0.25 `Reading` precedent). Heartbeat integration deferred.
- **Surfaces:** both — per-turn verdicts on `/conversations`, a desk scorecard on `/desks`.
- **Gating:** new `config.conversation_tending` (default off → byte-identical).

## Design

### 1. `Chat::Turn` as a `Tendable`

```ruby
class Enliterator::Chat::Turn < Enliterator::ApplicationRecord
  include Enliterator::Tendable          # visits/claims/measures/embeddings/etc., registry auto-skipped
  # ... existing v0.39 associations/validations ...
end
```

Additions:
- **`to_enliterator_text(facet:)`** — assembles the slice each facet judges, from `events` + `question`
  + the derived `answer` (see extractors). Facet-aware (the v0.4 `Tendable#enliterator_text` contract):
  - `turn_grounded` → question + answer + **the sources the desk cited** (record metadata + tool-returned records, pulled from `events`)
  - `turn_answered` → question + answer
  - `turn_register` → answer + **the register/persona text in force** (resolved from `persona_id` / the desk's effective composed prompt)
  - `turn_move` → question + the **action sequence** (tool calls + args + results + handoffs, in order, from `events`) + the **rendered output** (the answer/artifact) + **the actions the surface afforded** (the desk's tool/route allow-list)
- **`title`** — the label contract (`"Turn #{ordinal}: #{question.truncate(60)}"`), so Catalog/Atlas/Status drill-downs that read `try(:title)` work polymorphically.
- **Private extractors over `events`** (pure, symbol+string-key tolerant — the v0.39 Recorder discipline): `cited_sources`, `tool_calls` (`[{name, args, result_summary}]`), `answer_text`, `effective_register`. These are the single source the facets and the measure read; spec-pinned against a canned `events` array.

Turns are **not embedded** (turn embeddings are deferred), so the Visitor's neighbor gather is
gracefully empty — the judge reads the turn slice + prior verdicts (`literacy_state`), no neighbors.

### 2. The rubric

**Judged facets** (controlled vocabulary; each its own role + tier; `scheduled: false`):

| Facet | Tier | `verdict` value vocabulary | Detail claim |
|---|---|---|---|
| `turn_grounded` | strong | `grounding_verdict`: `grounded` / `partially_grounded` / `ungrounded` / `not_applicable` | `unsupported_claims[]` |
| `turn_answered` | mid | `answered_verdict`: `answered` / `partially` / `deflected` / `refused_appropriately` | `gap` |
| `turn_register` | cheap | `register_verdict`: `held` / `minor_lapse` / `broke` | `register_lapses[]` |
| `turn_move` | strong | `move_verdict`: `apt` / `suboptimal` / `mismatched` / `not_applicable` | `better_move` |

The verdict is the claim key (`grounding_verdict` / `answered_verdict` / `register_verdict` /
`move_verdict`); its value is the enumerated vocabulary; the detail is a second key per facet. Tiers
above are indicative — they are policy-configurable (`Staffing::Policy`), so a cost-sensitive
deployment can dial the judges down; grounded and move carry the substantive judgments and default to
the strong tier, register is mechanical-enough for the cheap tier.

Escape valves are load-bearing — they're the difference between measuring quality and punishing
correct behavior: `not_applicable` (grounding) = a turn that needed no sources (greeting, clarify,
handoff); `refused_appropriately` (answered) = a desk correctly declining out-of-scope/no-holdings —
a *win*, not a miss; `not_applicable` (move) = a turn with no navigation-action dimension.

`turn_grounded` borrows the **`Audit::Examiner`** discipline in its prompt (verify assertions against
the cited evidence; don't false-flag on snippet bounds; blind to prior verdicts) — but the *mechanism*
is the ordinary Visitor loop, not the Audit sampler (which stratifies over claims, inapplicable to
turns).

`turn_move` judges against the **full output space** — prose / search-config / widget / generated
artifact (e.g. HTML/JS/CSS rendering a 3D model) / graph view — defined as *actions-recorded vs
actions-afforded*, NOT against chat specifically. That generality is the point: when HSDL adopts a
conversational-search surface, its turns' `events` carry *its* action vocabulary and the **same facet
judges them** with no redefinition. The desk is one of many presentation tools; the facet travels.

**Computed measure** (no LLM): `tool_efficiency` via `Measures.register(:tool_efficiency)` — weighted
signals over the action sequence: tool-call count, redundant/duplicate calls (same tool+args), steps
vs the desk's `step_cap`, `budget_hit`, `elapsed_ms`, handoff count.

### 3. Verdict vocabularies = value-level authority control (the one engine extension)

Today a facet's controlled vocabulary enums claim **keys** ("the schema enums each claim `key` to the
allowed set"). The judged facets additionally need the verdict **value** constrained to its enum
(`grounded` / `partial` / …). So conversation-tending introduces **value-level vocabularies**: the
facet declares, per key, an allowed value set, and the structured-output schema enums the value, not
just the key. Reconciliation keeps the existing safety net (an off-enum verdict is rejected, mirroring
"off-list keys are dropped"). This is the single place v2 *extends* the engine rather than purely
reusing it; everything else is the standard loop.

### 4. Staffing

Declare the three judged facets in `Staffing::Policy` with `scheduled: false` and value-bearing
`terms:`, e.g.:

```ruby
facet :turn_grounded, tier: "quality", scheduled: false, terms: {
  grounding_verdict: { desc: "…", values: %w[grounded partially_grounded ungrounded not_applicable] },
  unsupported_claims: { desc: "answer assertions not traceable to a cited source" }
}
# turn_answered (mid), turn_register (cheap) likewise
```

`scheduled: false` keeps them out of heartbeat planner lanes (no unsupervised conversation-judging);
the registry auto-skip keeps tended turns out of the corpus census/survey. **Rule that bites (the Part
precedent):** verify both hold — a spec pins that tending a `Turn` adds nothing to `Visit.host_tendable_types`
counts, planner root lanes, or the census.

### 5. Invocation — `Chat::Tending`

`Chat::Tending.run(limit:, desk:, since:, force:)` (deliberate, bounded — the `Tending::Reading` shape):
selects **untended** turns (no succeeded visit on the quality facets) and, for each:
`turn.tend!(facet: …)` for the three judged facets + `Measures.recompute!(turn)` for `tool_efficiency`.
**Re-judging is explicit** — `force:` (a `FORCE=1` on the rake) re-tends already-judged turns so a
stronger judge can supersede prior verdicts (the compounding path); automatic staleness detection (re-judge
when the judge model/rubric version changed) is deferred. Front door:
**`rake enliterator:tend_conversations [LIMIT= DESK= SINCE= FORCE=1]`** (the Reading-pilot precedent).
`Chat::Eval` may optionally tend the turn it just produced (eval → score in one shot). Heartbeat
integration is **deferred/named**.

**Rule that bites:** `Measures.recompute!` runs *every* registered measure on the record being tended,
so `tool_efficiency`'s block must guard `return unless tendable.is_a?(Chat::Turn)` — otherwise it fires
(and errors) when a collection record is tended.

### 6. The scorecard — computed + cached

A `Chat::Quality` read-model rolls verdict claims + the measure up per turn → per conversation → per
desk: `% grounded` (of grounded+partial+ungrounded, **excluding `not_applicable`**),
`% answered` (with `refused_appropriately` counted as a win), `% register held`, `% apt move`,
`avg tool_efficiency`, `n judged`, `last judged at`. **Computed + cached** (the v0.20 `Synopsis` /
`Audit.accuracy` idiom — keyed by latest turn-visit + count, short TTL), no denormalized table.
Desk-quality-*over-time* later derives from the claims' own supersession history (claims are versioned),
so even history needs no new table.

### 7. Surfaces (both, gated, inline vanilla)

- **`/conversations`** (per-turn): each browsed/replayed turn gets quality badges (grounded ✓/partial/✗,
  answered, register, apt-move) + the tool-efficiency score; `unsupported_claims` / `gap` /
  `register_lapses` / `better_move` in a `<details>`. An untended turn reads "not yet judged."
- **`/desks`** (scorecard): beside each persona, the rollup panel — where v3's feedback loop will act.
- Both reuse the `enl-*` / shared component CSS (hard rule 2).

### 8. Gating & byte-identity

`config.conversation_tending` (default nil/off): no facets tended, no quality DOM on either surface,
no `Chat::Quality` reads — byte-identical to v0.41. Codified by an off-view regression spec (the
v0.28/v0.29 pattern). Independent of `chat_retention` but only meaningful with retained turns.

### 9. Migrations (rule 7)

**None for tables** — judgments reuse the polymorphic claim/visit/measure tables. (The only schema
touch would be an index if profiling shows the per-turn visit lookup is hot; decide in the plan, not
assumed.)

## v2 scope (YAGNI)

`Turn` includes `Tendable` (+ `to_enliterator_text(facet:)`, `title`, event extractors); value-level
verdict vocabularies (the schema extension); the 3 judged facets + the `tool_efficiency` measure;
`Chat::Tending` service + `enliterator:tend_conversations` rake; the computed+cached `Chat::Quality`
scorecard; per-turn badges on `/conversations` + the desk scorecard on `/desks`; `config.conversation_tending`
gating. Compounding proven by a re-judge-supersedes spec.

## Deferred / named

- **v3 — feedback into personas/register:** tended conversations propose desk-voice improvements,
  closing to the v0.37 persona editor (a governed suggestion surface for the voice). The reason the
  scorecard lives on `/desks`.
- **Per-action first-class tending:** make each *action* a tendable the way `Part` made each section
  one (a turn as a "work," its actions as "parts," tended then synthesized into the move verdict). Needs
  an explicit, typed action taxonomy (today `events` captures tool-use/handoffs/output but not explicit
  `think`/`select-output` steps — v2's judge infers from what's captured). The generative-artifact turns
  are where it will pay.
- **Heartbeat integration:** a conversation-tending phase in the nightly cycle, once facets are proven
  (the Reading→heartbeat path).
- **Turn embeddings / "similar conversations":** YAGNI for measurement.
- **SPEC.md / About sections:** per the standing directive, v0.42 lands them with the build (not
  commit-only — we just cleared that debt).
