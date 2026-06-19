# Lacunae — data-quality as the collection's knowledge of its own gaps

*Design doc · 2026-06-18 · foundation (record-level)*

## Thesis

**How do we know what we don't know?** A literate collection should be able to
enumerate its own gaps — not just what it has learned, but what it has *looked
for and failed to find*. This feature gives the engine that organ: a first-class
record of an expected-but-absent fact, opened when tending can't satisfy a
required term, diagnosed as to *why*, and closed when a later visit supplies it.

At its most precise, the present act is an **eviction**: the engine stops asserting a
contentless claim — an empty required value dressed as a `draft` — and replaces it with a
named not-knowing. The collection's *enumeration* of its own gaps is what that cleared,
queryable space unlocks downstream (onboarding, coverage). The question above is the
reach; the eviction is the foundation. (See *What this really is* and the sequence of
refusals it belongs to.)

## The problem, concretely

A 2006 NPS thesis (`DocMetum/060f8133-…`) carries a live `authored_by` claim
with an **empty value**, confidence `0.1`, status `draft`. The engine is behaving
correctly: `authored_by` is a *required* term for the `authorship` facet, the
title-page slice the model reads is missing the author (a docling table-extraction
artifact dropped the byline — the slice literally ends `…INFORMATION by` with no
name, while the advisors survived in a clean cell), so both tiers returned an empty
value, the visit flagged `required_unmet: true`, and `reconcile!` wrote the empty
claim anyway.

The result is an undifferentiated blank in the claim store — noise that reads, to a
user, as a broken record. A cataloger never leaves a required element blank. They
diagnose *why* it's missing and record that. This feature models that discipline.

### What this really is

The empty `authored_by=""` at conf 0.1 wearing the `draft` badge is not an absence of
belief — it is a *false* belief: a blank in the form of a claim-in-progress, the loop
asserting it has something when it has a known failure to find. So this feature is less
the addition of an organ than the next in a sequence of refusals to let fluent-but-empty
output pass as knowledge: the silent-failure guard (v0.5), the legibility gate (v0.17),
the audit (v0.18), and now the lacuna. Each evicts a parasite that had been borrowing the
form of a real claim. The lacuna does both at once — it *evicts* a standing false belief
(the empty draft) and *crystallizes* the cleared space into a queryable known-unknown. The
eviction is the present value; the organ is what later makes onboarding and coverage
lacunae buildable.

## The epistemic frame

Tending converts the collection's ignorance into one of three states:

| State | Meaning | Organ |
|---|---|---|
| **Unknown-unknown** | not yet examined — we don't know what's missing | the heartbeat **frontier** (exists) |
| **Known-unknown** | examined; a *required* element is absent, with a diagnosis | **Lacuna** (new) |
| **Known-known** | asserted | **Claim** (exists) |

A brand-new collection has **zero** lacunae — not because it is complete, but
because it is wholly ignorant; it does not yet know what it doesn't know. Lacunae
are *earned by looking*. This is why the design is **lazy** (a lacuna is born at
look-time, never pre-stamped): pre-stamping would claim to know what's missing
before having looked — an unknown-unknown masquerading as knowledge.

## The model: `Enliterator::Lacuna`

Table `enliterator_lacunae`. A first-class finding, sibling to `Suggestion` /
`Treatment`. The negative space of a claim.

Naming: in archives and rare-book cataloging a **lacuna** is a known gap (a missing
leaf, an absent element). It is the field's exact word and reads correctly to the
FEDLINK (federal-librarian) audience.

| Field | Purpose |
|---|---|
| `tendable` (polymorphic) | the record (or, in growth, a `Context`) the gap is in |
| `facet`, `key`, `context` | the dimension, required term, and collection context |
| `diagnosis` | LIS-grounded *why* (enum below) |
| `note` | the model's one-phrase justification |
| `status` | `open` / `closed` |
| `closed_reason` | `supplied` (automatic, foundation) / `dismissed` / `not_identified_confirmed` (curator closes — fast-follow; null while open) |
| `detected_in_visit`, `last_detected_at`, `detections` | first detection, recency, accrual count |
| `closed_by_visit` | the visit that supplied the value, on closure |

Identity is the tuple `(tendable, facet, key, context)`: **one open lacuna per
tuple**, enforced by a partial unique index `WHERE status = 'open'`. **Gotcha:**
`context_id` is nullable (NULL = root, the common case), and Postgres treats NULLs
as distinct — a plain unique index would *not* prevent duplicate root-context
lacunae. Use `NULLS NOT DISTINCT` (PG 15+) or, for portability, an expression index
over `COALESCE(context_id, '00000000-0000-0000-0000-000000000000'::uuid)`.
`open_or_refresh` also guards application-side (find-open-then-create at the single
`finalize_final_visit!` writer) so the constraint is a backstop, not the only line.

### `diagnosis` enum

| Value | Meaning | Eventual remedy |
|---|---|---|
| `defective_surrogate` | the fact is in the item but our extraction lost it (our thesis case) | re-extract / re-OCR (Condition's branch) |
| `silent` | the item genuinely omits it; an authority may know | supply from authority (later growth) |
| `not_identified` | genuinely unrecoverable | the RDA conventional state, recorded honestly |
| `undiagnosed` | gap is certain; cause not assessed (the model offered no diagnosis) | a human / later step assesses; route nowhere automatically |

The enum is small and extensible. `undiagnosed` is the no-info default — see
no-silent-failure below.

The three substantive values are **graded by the empirical check each admits**, and that
grading is the point: `defective_surrogate` means the check exists *in the source*
(re-extract and see if the value returns); `silent` means it exists *in an external
authority* (look elsewhere); `not_identified` means **no check exists** (source gone, no
authority). So the diagnosis taxonomy is, at bottom, a *checkability* taxonomy, and
`not_identified` is the lacuna-level twin of the audit's `unverifiable` verdict — both say
"no empirical check is available here, so this will not be scored as a finding." This is
the engine's standing posture (the legibility gate, the verify floor, the audit, now the
lacuna): assert no more than the ground licenses.

### The diagnosis is a hint, not a verdict

The two halves of a lacuna do not carry the same epistemic weight, and the doc must not
pretend they do. The **existence** of the gap is mechanical and certain: a required term
came back with a blank value, so a lacuna opens. The **diagnosis** is the same model's
unverified self-report — produced on the same call, from the same (possibly truncated)
slice that *caused* the gap. Asked whether `…INFORMATION by` is a *garbled* byline
(`defective_surrogate`) or an *absent* one (`silent`), the model is guessing from exactly
the impoverished view the case turns on. This is the examiner-shares-the-tender's-worldview
problem the audit (v0.18) exists to distrust.

So the three substantive diagnoses are set **only** on the model's affirmative report; the
absence of a report yields `undiagnosed`, never a defaulted cause (defaulting to `silent`
would itself assert a cause we did not determine — the very parasite this feature evicts,
re-entering through the fallback). The diagnosis is a low-stakes routing hint: it *suggests*
re-extraction vs. authority lookup, but it is not audited. The place the guess finally gets
checked is the deferred **Condition cross-wiring** — does re-extraction actually recover the
byline? — which closes the loop on the diagnosis the way the audit closes it on the claim.

### Lifecycle — the "compounds across visits" payoff

A lacuna **opens** when tending can't satisfy a required term, **refreshes** (not
duplicates) each beat it remains missing (bumping `detections` / `last_detected_at`),
and **closes** the moment a later visit supplies the value — leaving an auditable
trace: *author missing 2026-06-15 → closed 2026-06-20 by visit N supplying "Jane
Smith."* The same tending loop that writes claims now also closes gaps; the
collection visibly learns what it didn't know.

## How lacunae open and close

The chokepoint is one method: `Tending::Visitor#finalize_final_visit!`
(`app/services/enliterator/tending/visitor.rb`). It already computes `required` and
`final_unmet` and is the only place the staffing path writes claims. Gated on
`config.record_lacunae` (default **false**), before reconciling it:

1. **Partitions** the final tier's claims against the facet's `required` terms →
   *satisfied* vs *blank*.
2. **Opens/refreshes** a `Lacuna` for each blank required term, carrying the model's
   diagnosis — then **drops those blank claims** from the set handed to `reconcile!`.
   When the flag is on, the empty `authored_by=""` claim is never written; the lacuna
   replaces it. (This also closes a latent hazard: a later visit returning a blank
   required value can no longer supersede a previously-good claim — blanks never reach
   `reconcile!`.)
3. **Closes** any `open` lacuna whose required term *is* satisfied this visit
   (`closed_reason: "supplied"`, `closed_by_visit:`).

### The diagnosis comes from the contract, gated

The required-key prompt is extended: *for any required term you cannot fill from the
provided text, add an entry to an `absences` array — the term, a `diagnosis`
(garbled/truncated in the text = `defective_surrogate`; absent entirely = `silent`;
genuinely unknowable = `not_identified`), and a one-phrase note. If you genuinely cannot
tell which, omit the diagnosis — abstention is preferred to a guess.* An omitted (or
absent) diagnosis is recorded by the engine as `undiagnosed`; the model never returns
that value itself. Letting the model abstain is deliberate: it is being asked to classify
a failure it produced from a possibly-truncated slice, and a forced choice between
`defective_surrogate` and `silent` is exactly the call the thesis case shows is hard. This
rides the existing tend call — no extra spend, no extra round-trip. Lives in
`adapters/llm/base.rb` beside the contract/required blocks. The `absences` schema
property is present **only when the facet has required terms AND `record_lacunae` is
on**, so the off-path schema and outputs stay byte-identical (the v0.41.2 discipline).

### No silent failure (hard rule 3)

The lacuna opens whenever a required term is unmet, **regardless** of whether the
model supplied a clean `absences` entry. A missing diagnosis yields `undiagnosed`
(never a defaulted cause). The gap is never lost to a terse model, and a cause is never
invented for it.

### Back-compat (hard rule 1)

Flag off → `finalize_final_visit!` runs exactly as today: empty claim written,
`required_unmet` flag set, no `absences` in the schema, `enliterator_lacunae`
untouched. The existing `required_unmet` / verify-barring logic is unchanged (it
reads parsed claims, not persisted ones). The thesis's empty `authored_by` changes
only once HSDL sets `record_lacunae = true`.

## Surface

Start where the confusion started — the **record page**:

- **"Known gaps" panel** beside "Live claims" on the Status record page. Instead of
  the baffling empty `authored_by` row: *`authored_by` — defective_surrogate —
  "byline present but author name not captured in provided text."*

Then a collection rollup and the standard front doors:

- **Status rollup panel** showing the triad and gaps by facet × diagnosis:
  *Frontier: 312 unexamined · Open lacunae: 47 (authorship/defective_surrogate 34,
  authorship/silent 9, …) · Claims: 8,410.*
- **`rake enliterator:lacunae`** — CLI inventory.
- **MCP tool `lacunae`** — "what does this collection know it's missing."

A dedicated `/enliterator/lacunae` surface is **deferred** — the rollup panel proves
the value first, exactly as Audit began as a Status panel + `/review` before earning
its own surface. Panels render only when there is data, so off-path pages are
byte-identical.

## Relationships to existing organs

- **Condition (v0.17):** a `defective_surrogate` lacuna *is* a legibility problem.
  Foundation keeps them decoupled (the lacuna carries the diagnosis only). Cross-wiring
  — a `defective_surrogate` gap registering a condition signal so it lands in the
  conservation/re-extract queue — is a clean later increment.
- **Measures (completeness):** completeness can consume open-lacunae counts against
  required terms. An easy follow, not folded into the foundation.
- **Audit (v0.18):** orthogonal. Audit asks "is this claim *true*"; lacunae ask "is an
  expected claim *absent*." No overlap.

## Build discipline

- **Config:** `config.record_lacunae` (default false) gates all behavior above.
- **Migration (hard rule 7):** one reversible migration creating `enliterator_lacunae`,
  with a partial unique index on `(tendable_type, tendable_id, facet, key, context_id)
  WHERE status = 'open'`. Applied to `spec/dummy` and HSDL dev.
- **Indexes:** `[tendable_type, tendable_id]`, `[context_id]`, `[facet, key]`,
  `[status]`, plus the partial unique index above.
- **Tests:**
  - Visitor: off → byte-identical (empty claim written, no lacuna, schema unchanged);
    on → blank required term opens a lacuna + no empty claim + diagnosis captured;
    satisfied required term closes an open lacuna; a missing or abstained diagnosis
    yields `undiagnosed` (never a defaulted cause); refresh-not-duplicate across two
    beats; existing good claim never superseded by a blank.
  - `Lacuna` model: `open_or_refresh` upsert, `close!`, uniqueness, lifecycle.
  - Contract golden: `absences` property present only when required ∧ flag on;
    off-path output byte-identical.
  - Request specs: record-page panel and Status rollup render on data, absent off.
  - Rake + MCP tool.

## What this lets us measure

The lifecycle hands us a clean, cheap proxy for the engine's central claim —
*understanding compounds across visits* — instrumented with a tombstone. A lacuna that
**closes** is a dated, auditable instance of a later visit supplying what an earlier one
could not: *author missing 2026-06-15 → closed 2026-06-20 by visit N supplying "Jane
Smith."* That is the trajectory claim with a body to point at.

- **Closure rate** is a free byproduct of the foundation: opened vs. closed lacunae over
  a window, by facet and diagnosis.
- **Causal-closure** is the richer, load-bearing number and a deliberate follow: not just
  *that* a gap closed but *because the surroundings changed* — a re-extraction, a new
  neighbor, a vocabulary approval. It needs correlating `closed_by_visit` with what changed
  (the visit's `input_refs` / the heartbeat `reason`). A cohort that closes when surroundings
  change and stays open when they don't is compounding *measured*, not asserted — the
  statistic the Enliteracy chapter should cite in place of its softest analogy.

## Designed-in growth (documented, not built)

The polymorphic model carries both of the following with **no schema change** — only
a new *producer* and new *sources of expectation*:

1. **Collection-coverage lacunae** — `tendable` = `Context`; e.g. "11 states absent,"
   "series missing 2024." Lacunae of the *set*, not the member. Needs collection-level
   expectations to check against.
2. **Onboarding / description lacunae** — `tendable` = `Context`, `facet: "description"`,
   `key: "required_terms" | "derived_text" | "scope"`. The spine of the onboarding loop
   (its own design doc): the AI's shape-visit opens description lacunae about *how to
   read the collection*; the curator's answers close them and author the enliteration
   spec. This is the `enliterating-a-collection` skill given a data spine and a surface,
   and the ambient-specification loop pointed at intake.
3. **Expectation authority (the asymmetric third)** — subject authority self-governs
   *keys*, name authority self-governs *values*; the missing third would self-govern
   *required-ness* (what counts as a gap). A recurring dimension could *propose* that its
   absence is itself a finding. But this symmetry is not clean, and the gate it needs is
   the point: key/value authority is **additive and descriptive** (a new key is just an
   allowed claim), whereas required-ness is **normative** — it declares every record
   lacking the term deficient. "This dimension recurs" (is) → "its absence is a finding"
   (ought) is exactly the is/ought leap this design otherwise refuses. So recurrence may
   *propose* required-ness, but only a governance act (a considerer-style hold-for-approval)
   may license it; auto-promotion would flood the surface with a corpus-wide deficiency the
   instant a term crossed the threshold. Real direction, gated.

## Known limits

State these plainly so the feature is not oversold:

- **The required-terms floor.** A gap can only be *known* if a human declared the term
  required. Lacunae therefore measure the collection's **diligence against its catalogers'
  foresight** — the gaps in dimensions we already knew to expect — not its full ignorance.
  A genuinely unknown-unknown (a dimension nobody made required) produces no lacuna, because
  nothing looked for it. The frontier still holds that layer; the lacuna does not. "Knowing
  what it doesn't know" is, precisely, *knowing the expected things it failed to find* — real
  and worth having, but narrower than the unqualified phrase. (Expectation authority, in
  growth, is the partial answer — gated by the is/ought caveat above.)
- **The diagnosis is unverified.** Gap existence is certain; gap *cause* is the tender's
  guess (see "The diagnosis is a hint, not a verdict"). A misdiagnosis routes the eventual
  remedy down the wrong branch. The Condition cross-wiring (deferred) is what would check it.

## Out of scope (YAGNI for the foundation)

- Active recovery (re-reading other sources; consulting external authorities). The
  diagnosis names the remedy; performing it is later growth.
- Condition cross-wiring and Measures consumption (noted as easy follows).
- A dedicated lacunae surface (panel first).
- Curator-initiated close (dismiss / confirm-not-identified). The model carries the
  `dismissed` / `not_identified_confirmed` states; the control is a small fast-follow.
  The foundation closes a lacuna only automatically, when a later visit supplies the
  value (`closed_reason: "supplied"`).
- Collection-level and onboarding lacunae (the model is shaped for them; the producers
  are separate features).
