# Patron Model — Design (v0.42)

**Goal:** Model the **patron** — the cognition (human or agent) at the reference desk — by *tending the
conversation*. `Chat::Conversation` becomes a `Tendable` with a `patron` facet that infers WHO is asking
(`patron_persona`) and WHAT they want (`patron_intent`) from the conversation's turns, sharpening as the
interview grows. This is the half the engine never modeled — it models the *responder* (the desk's
register + persona, v0.36/v0.37) but not the *asker* — and it's the input v0.43's turn-quality judges
need: "answered" and "apt move" are intent-relative.

**Status:** Approved design (brainstorm 2026-06-14). First of two versions (v0.42 patron model → v0.43
turn quality, which reads it). Next: implementation plan → subagent-driven build.

## The elegant core

A reference librarian forms a model of the patron *over the interview* — vague at "hi, I'm researching
ports," sharp by the tenth exchange. That is tending: each turn adds evidence, the model is reconciled
(not overwritten), it carries provenance. So:

- **`Chat::Conversation` includes `Tendable`** — the v0.25 `Part` move, one level up: the whole loop
  (visits, claims, reconciliation, escalation) polymorphically; the registration rule auto-skips any
  `Enliterator::*` class, so modeled conversations never enter planner lanes, the corpus census, or the
  condition survey; **no new tables**.
- **The `patron` facet** tends the conversation — reads the turns (the *questions* especially: how
  someone asks reveals who they are) and emits `patron_persona` + `patron_intent` claims.
- **Sharpening = reconciliation.** A new turn moves the conversation's `updated_at` (the source-change
  signal); a re-tend UPDATEs the patron claims — a 1-turn guess becomes a 10-turn certainty, the
  supersession chain recording how the model formed.
- **The persona vocabulary self-governs — for free.** Because `patron_persona` is a controlled-vocabulary
  facet, an asker who fits no known type surfaces an off-vocabulary observation → a `Suggestion` → the
  considerer → a curator ratifies a new patron type. The patron taxonomy tends itself, like every other
  vocabulary in the engine.

## Naming

**`patron`, not `visitor`.** `Tending::Visitor` is *already* the tending agent — a "visitor facet" beside
it is the exact homonym the CLAUDE.md vocabulary section warns against. And `patron` is the LIS-native
term (a reference desk serves patrons) — build IN to library science. So `patron_persona`, `patron_intent`,
the `patron` facet.

## Design

### 1. `Chat::Conversation` as a `Tendable`

```ruby
class Enliterator::Chat::Conversation < Enliterator::ApplicationRecord
  include Enliterator::Tendable      # claims/visits/measures, registry auto-skipped (Enliterator::*)
  # ... existing v0.39 associations/validations ...
end
```

- **`to_enliterator_text(facet: :patron)`** assembles the conversation's turns in order — each patron
  question, plus a bounded shape of the desk's responses — into the text the patron-judge reads. The
  questions carry most of the signal (vocabulary, specificity, framing distinguish faculty / student /
  analyst).
- **`title`** — the label contract (`label.presence || "Conversation #{id}"`).
- Conversations aren't embedded; the judge reads the turns + prior patron claims (`literacy_state`),
  neighbors gracefully empty.

### 2. The `patron` facet

A judged facet (`scheduled: false`), controlled value-level vocabulary:

| Claim key | Value vocabulary | Note |
|---|---|---|
| `patron_persona` | host-seeded enum (§3) + `unknown` | who is asking — stable across the conversation; self-governing |
| `patron_intent` | `scope_a_topic` / `find_a_fact` / `survey_literature` / `build_a_brief` / `verify_a_claim` / `explore` / `teaching_prep` / `other` | the session goal |
| `intent_summary` | free text (bounded) | the specific goal in plain words ("the gaps in maritime port-security scholarship") |
| `ambiguity_note` | free text (bounded) | what's still unresolved — drives the next turn's sharpening |

Tier: **mid** (persona/intent inference is a moderate judgment); policy-configurable.

### 3. The patron persona vocabulary (host-seeded, self-governing)

The engine ships a **generic default** (`researcher` / `practitioner` / `student` / `agent` / `unknown`).
The host declares its own — **HSDL's seed** (Jeremy, 2026-06-14):

- `chds_faculty`, `chds_staff`, `chds_student` — their differing uses of the collection
- `policy_analyst_federal`, `policy_analyst_state`, `policy_analyst_local` — policy analysts across levels
  of government
- `unknown`

Declared in the host's `Staffing::Policy` patron-facet `terms:`. New patron types arrive via the
suggestion loop (the seed is a starting point, not a ceiling).

### 4. Value-level vocabulary — the engine extension (lands here, reused in v0.43)

Today a facet's vocabulary enums claim **keys** ("the schema enums each claim `key` to the allowed set").
`patron_persona`/`patron_intent` need the **value** constrained to an enum. So v0.42 introduces
**value-level vocabularies**: a facet term may declare `values: [...]`, the structured-output schema
enums the value (not just the key), and reconciliation rejects an off-enum value (the existing "off-list
keys are dropped" safety net, one level down). This is the single place v0.42 *extends* the engine rather
than purely reusing it; v0.43's verdict vocabularies reuse the same mechanism.

### 5. Invocation — `Chat::PatronModel`

`Chat::PatronModel.run(limit:, since:, force:)` (deliberate, bounded — the `Tending::Reading` shape):
tends conversations untended on the `patron` facet (a conversation with new turns since its last patron
visit reads as untended — source-change), `force:` to re-tend. Front door:
**`rake enliterator:model_patrons [LIMIT= SINCE= FORCE=1]`**. `Chat::Eval` may model the patron of a
conversation it generates.

### 6. Surface — "who uses the collection, and for what"

A patron-mix view (on `/conversations`, or a small section there): the distribution of `patron_persona`
across modeled conversations, the common `patron_intent`s, and drill-into-a-conversation to see its
patron model + the turns that formed it (with provenance). Gated. This is a genuine insight surface on
its own — *the collection learns who it serves* — and it's where v0.43's scorecard will later cross
persona × quality. Inline vanilla, shared components (hard rule 2).

### 7. Gating & byte-identity

`config.patron_modeling` (default off): no patron facet tended, no patron surface — byte-identical to
v0.41. (Or fold v0.42 + v0.43 under one `config.conversation_tending` umbrella — decide in the plan.)
Off-view regression spec (the v0.28/v0.29 pattern).

### 8. Migrations (rule 7)

None for tables — `Conversation` gets the polymorphic claims/visits/measures. (An index on visits only
if the per-conversation lookup profiles hot — decide in the plan, not assumed.)

### Rules that bite

- **Part precedent:** verify Conversation-as-Tendable stays out of `Visit.host_tendable_types` counts,
  planner root lanes, and the census (registry auto-skip + `scheduled: false`); spec-pinned, as Part is.
- **`Tending::Visitor` vs patron:** the homonym is *why* we chose `patron`; keep code rigorously on
  `patron_*` for the asker and `Visitor` for the tender.
- **Conversation already has a `label` and `source`** (v0.39) — the patron facet adds claims, it does not
  repurpose those columns.

## v0.42 scope (YAGNI)

`Chat::Conversation` includes `Tendable` (+ `to_enliterator_text(facet: :patron)`, `title`); value-level
vocabularies (the schema extension); the `patron` facet (persona + intent + summaries); the generic
default + HSDL-seeded patron vocabulary; `Chat::PatronModel` service + `enliterator:model_patrons` rake;
the patron-mix surface; `config.patron_modeling` gating. Sharpening proven by a re-tend-supersedes spec
(mirrors `visitor_spec`).

## Deferred / named

- **v0.43 — turn quality:** the 4 judged facets (`turn_grounded` / `turn_answered` / `turn_register` /
  `turn_move`) + `tool_efficiency`, with the answered/move judges **reading this patron model**, plus the
  desk scorecard (persona × quality) and per-turn badges. Separate design doc:
  `2026-06-14-turn-quality-design.md`.
- **Per-turn immediate intent:** v0.42 models the session-level patron; a per-turn intent claim is a
  later refinement (the question text already carries it for the v0.43 judges).
- **Dedicated patron-vocabulary review surface:** the suggestion loop is free (it's a facet), but a
  patron-specific review UI (vs the shared `/suggestions`) is deferred.
- **SPEC.md / About sections:** land with the build (doc-debt cleared 2026-06-14; the standing directive
  holds).
