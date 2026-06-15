# Turn Quality — Design (v0.43)

**Goal:** Tend each retained chat **turn** along conversation-quality facets so the desk's own ability
becomes *measured* and *compounding*, rolled up to a per-desk scorecard crossed with **patron persona**.
This is the measurement payoff; it sits on the v0.42 **patron model** (the answered/move judges read it).
Feeding quality back into persona/register editing is **v3** (named, designed-for, not built here).

**Status:** Approved design (brainstorm 2026-06-14). Second of two versions — **depends on v0.42**
(`2026-06-14-patron-model-design.md`): the patron model is the judging context for `turn_answered` and
`turn_move`. Next (after v0.42 ships): implementation plan → subagent-driven build.

## The elegant core

Three facts make this near-pure reuse:

1. **`Chat::Turn` becomes a `Tendable`** — the v0.25 `Part` move (as v0.42 did for `Conversation`). The
   whole loop, polymorphically; registry auto-skipped; **no new tables**.
2. **The `events` jsonb already holds the turn's action sequence.** A turn is a **move** composed of
   zero-or-more **actions** (input → think → use tools → consider results → select output → render); the
   Loop already recorded those actions in `events`. We judge over the sequence, we don't invent it.
3. **The judges read the v0.42 patron model**, so "answered" and "apt move" are evaluated against *who is
   asking and what they want*, not in a vacuum.

And the thesis holds though a turn is **frozen**: re-tending re-judges with a *better judge* — a stronger
model, a sharper rubric, or a sharper patron model — and *supersedes* the prior verdict via ordinary
reconciliation. The turn never changes; the judgment compounds. The recursion, real.

## Decisions (from the brainstorm)

- **Primary payoff:** quality *measurement* — the smallest honest version that yields a real instrument.
  Feedback-into-personas = v3.
- **Rubric:** **4 judged facets** (`turn_grounded`, `turn_answered`, `turn_register`, `turn_move`) **+ 1
  computed measure** (`tool_efficiency`). Don't pay a model to count tool calls.
- **The move/action model:** `turn_move` is the *judged whole* (was this the right move?); the actions are
  the `events`; `tool_efficiency` *computes* economy over the same sequence. Per-action first-class
  tending (the `Part` pattern one level deeper) is the named future.
- **Intent comes from the patron model (v0.42), not inline inference.** `turn_answered` and `turn_move`
  read the conversation's `patron_persona` + `patron_intent` claims as judging context.
- **Surfaces:** per-turn verdicts on `/conversations`; a desk scorecard on `/desks`, crossed by persona.
- **Gating:** `config.conversation_tending` (or the shared umbrella flag from v0.42).

## Design

### 1. `Chat::Turn` as a `Tendable`

```ruby
class Enliterator::Chat::Turn < Enliterator::ApplicationRecord
  include Enliterator::Tendable          # visits/claims/measures, registry auto-skipped
  # ... existing v0.39 associations/validations ...
end
```

Additions:
- **`to_enliterator_text(facet:)`** — assembles the slice each facet judges, from `events` + `question` +
  the derived `answer`, **plus the parent conversation's patron model** for the intent-relative facets:
  - `turn_grounded` → question + answer + the **cited sources** (record metadata + tool-returned records, from `events`)
  - `turn_answered` → question + answer **+ `conversation` patron_persona/patron_intent**
  - `turn_register` → answer + the **register/persona in force** (from `persona_id` / the desk's composed prompt)
  - `turn_move` → question + the **action sequence** (tool calls/args/results/handoffs, in order) + the **rendered output** + the **actions afforded** (the desk's tool/route allow-list) **+ patron_persona/patron_intent**
- **`title`** — `"Turn #{ordinal}: #{question.truncate(60)}"` (the label contract).
- **Private extractors over `events`** (pure, symbol+string-key tolerant — the v0.39 Recorder discipline):
  `cited_sources`, `tool_calls`, `answer_text`, `effective_register`. Single source for the facets and the
  measure; spec-pinned against a canned `events` array.

Turns aren't embedded (deferred), so the Visitor's neighbor gather is gracefully empty — the judge reads
the turn slice + the patron model + prior verdicts (`literacy_state`).

### 2. The rubric

**Judged facets** (value-level controlled vocabulary — the v0.42 mechanism; `scheduled: false`):

| Facet | Tier | Verdict key + value vocabulary | Detail |
|---|---|---|---|
| `turn_grounded` | strong | `grounding_verdict`: `grounded` / `partially_grounded` / `ungrounded` / `not_applicable` | `unsupported_claims[]` |
| `turn_answered` | mid | `answered_verdict`: `answered` / `partially` / `deflected` / `refused_appropriately` | `gap` |
| `turn_register` | cheap | `register_verdict`: `held` / `minor_lapse` / `broke` | `register_lapses[]` |
| `turn_move` | strong | `move_verdict`: `apt` / `suboptimal` / `mismatched` / `not_applicable` | `better_move` |

Tiers are indicative — policy-configurable (`Staffing::Policy`); grounded and move carry the substantive
judgments and default strong, register is mechanical-enough for cheap.

Escape valves are load-bearing — they separate measuring quality from punishing correct behavior:
`not_applicable` (grounding) = a turn that needed no sources; `refused_appropriately` (answered) = a desk
correctly declining out-of-scope/no-holdings, a *win* judged against the patron's intent; `not_applicable`
(move) = no navigation-action dimension.

`turn_grounded` borrows the **`Audit::Examiner`** discipline in its prompt (verify against cited evidence;
don't false-flag on snippet bounds; blind to prior verdicts) — but the *mechanism* is the Visitor loop.

`turn_move` judges against the **full output space** — prose / search-config / widget / generated artifact
(HTML/JS/CSS rendering a 3D model) / graph view — defined as *actions-recorded vs actions-afforded*, NOT
chat-specifically. When HSDL adopts a conversational-search surface, its turns' `events` carry *its* action
vocabulary and the same facet judges them, no redefinition. The desk is one of many presentation tools.

**Computed measure** (no LLM): `tool_efficiency` via `Measures.register(:tool_efficiency)` — weighted
signals over the action sequence: tool-call count, redundant/duplicate calls, steps vs the desk's
`step_cap`, `budget_hit`, `elapsed_ms`, handoff count.

### 3. Invocation — `Chat::Tending`

`Chat::Tending.run(limit:, desk:, since:, force:)` (deliberate, bounded): selects **untended** turns (no
succeeded visit on the quality facets) and for each runs `turn.tend!(facet: …)` for the three judged
facets + `Measures.recompute!(turn)`. **Re-judging is explicit** — `force:` (`FORCE=1`) re-tends so a
stronger judge supersedes prior verdicts (the compounding path); automatic staleness detection is deferred.
Front door: **`rake enliterator:tend_conversations [LIMIT= DESK= SINCE= FORCE=1]`**. `Chat::Eval` may tend
the turn it just produced. Heartbeat integration is deferred/named.

**Rule that bites:** `Measures.recompute!` runs *every* registered measure on the record being tended, so
`tool_efficiency`'s block must guard `return unless tendable.is_a?(Chat::Turn)` — otherwise it fires (and
errors) when a collection record (or a Conversation) is tended.

**Ordering:** model the patron (v0.42) before tending its turns, so the answered/move judges have a patron
model to read; `Chat::Tending` warns (not fails) when a turn's conversation is unmodeled and falls back to
the question text alone (graceful — rule 3).

### 4. The scorecard — computed + cached, crossed by persona

A `Chat::Quality` read-model rolls verdict claims + the measure up per turn → per conversation → per desk,
**and per `patron_persona`** (the v0.42 model): `% grounded` (of grounded+partial+ungrounded, *excluding
`not_applicable`*), `% answered` (with `refused_appropriately` a win), `% register held`, `% apt move`,
`avg tool_efficiency`, `n judged`, `last judged at` — sliceable by persona ("the desk is 91% apt for
`chds_student` but 70% for `policy_analyst_federal`"). **Computed + cached** (the v0.20 `Synopsis` /
`Audit.accuracy` idiom — keyed + short TTL), no denormalized table; desk-quality-over-time later derives
from the claims' own supersession history.

### 5. Surfaces (both, gated, inline vanilla)

- **`/conversations`** (per-turn): each browsed/replayed turn gets quality badges (grounded ✓/partial/✗,
  answered, register, apt-move) + the tool-efficiency score; `unsupported_claims` / `gap` /
  `register_lapses` / `better_move` in a `<details>`; an untended turn reads "not yet judged."
- **`/desks`** (scorecard): beside each persona, the rollup panel with the persona breakdown — where v3's
  feedback loop will act.
- Both reuse the `enl-*` / shared components (hard rule 2).

### 6. Gating & byte-identity

`config.conversation_tending` (default off): no quality facets tended, no quality DOM on either surface,
no `Chat::Quality` reads — byte-identical to v0.42. Codified by an off-view regression spec.

### 7. Migrations (rule 7)

None for tables — judgments reuse the polymorphic claim/visit/measure tables. (An index only if profiling
shows the per-turn visit lookup hot — decide in the plan.)

## v0.43 scope (YAGNI)

`Turn` includes `Tendable` (+ `to_enliterator_text(facet:)`, `title`, event extractors); the 3 judged
facets (reusing v0.42's value-level vocabularies) + the `tool_efficiency` measure; the judges read the
v0.42 patron model; `Chat::Tending` service + `enliterator:tend_conversations` rake; the computed+cached
`Chat::Quality` scorecard crossed by persona; per-turn badges on `/conversations` + the desk scorecard on
`/desks`; `config.conversation_tending` gating. Compounding proven by a re-judge-supersedes spec.

## Deferred / named

- **v3 — feedback into personas/register:** tended conversations propose desk-voice improvements, closing
  to the v0.37 persona editor (a governed suggestion surface for the voice). The reason the scorecard lives
  on `/desks` and is crossed by persona.
- **Per-action first-class tending:** make each *action* a tendable the way `Part` made each section one (a
  turn as a "work," its actions as "parts," tended then synthesized into the move verdict). Needs an
  explicit typed action taxonomy (today `events` captures tool-use/handoffs/output but not explicit
  `think`/`select`/`render` steps — v0.43's judge infers from what's captured). The generative-artifact
  turns are where it will pay.
- **Heartbeat integration:** a conversation-tending phase in the nightly cycle, once facets are proven.
- **Turn embeddings / "similar conversations":** YAGNI for measurement.
- **SPEC.md / About sections:** land with the build.
