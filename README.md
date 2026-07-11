# Enliterator

**Confer literacy on data.** Enliterator is a mountable Rails 8 engine. Mount it,
`include Enliterator::Tendable` on any host model, and that record gains a
provenance-tracked store of understanding that **compounds over time**: each
scheduled visit reads the record's accumulated claims plus its corpus neighbors,
reconciles its interpretation through a language model, and leaves the record
more literate than it found it.

## What & why

Most "AI enrichment" is one-shot: run a model over a row, store the output,
move on. The output never improves; if the model was wrong, it stays wrong; there
is no record of *why* a field holds the value it does. Enliterator replaces that
with a **closed tending loop**. Understanding is stored as discrete, reconcilable
**Claims** with full PROV-style provenance (what generated them, what they were
derived from, who attributed them). Each new **Visit** is handed the prior
claims and recent visits as context, so the model revises in light of what it
already concluded rather than starting from zero. That feedback — prior visits
conditioning the next — is what makes understanding *compound*.

First consumer: **HSDL** (Homeland Security Digital Library). Substrate: AWS
Bedrock (Claude) for the LLM, OpenAI `text-embedding-3-small` (1536d) for
embeddings, Sidekiq for jobs. Nothing in the engine depends on Solid Queue — all
jobs are plain ActiveJob, so they run on whatever queue backend the host already
uses.

## The literacy ladder

Each rung adds a capability the rung below lacks. Enliterator's value is rung 5;
the lower rungs are the load-bearing structure that makes rung 5 honest.

| Rung | Literacy | What it means | In Enliterator |
|------|----------|---------------|----------------|
| 1 | **searchable** | the text can be found by similarity | `Embedding` rows + HNSW cosine index; `Embedding.nearest_to` |
| 2 | **structured** | understanding is discrete fields, not a blob | `Claim` rows keyed by `key` with typed `value` |
| 3 | **provenanced** | every claim knows where it came from | `visit_id` (wasGeneratedBy), `derived_from` (wasDerivedFrom), `attributed_to` (wasAttributedTo) |
| 4 | **tended** | understanding is maintained, not abandoned | the event-driven heartbeat (`enliterator:heartbeat`): frontier first, re-tend on change, budget-capped, on a ledger |
| 5 | **compounding** | each visit improves on the last | the Visitor hands prior claims + recent visits into the next visit's context; claims are reconciled (ADD/UPDATE/DELETE/NOOP), not overwritten |

Beneath the rungs sits the substrate's own ladder (v0.17 — digital preservation's):
**present → intact → extractable → intelligible**. Host-registered condition probes
(`Enliterator::Condition.register`) shelf-read the collection on the heartbeat — link checking,
fixity/format validation, extraction quality — and records the engine cannot read are pulled
from every tending queue until repaired. What can't be probed is intelligibility: there the
tending loop itself is the instrument, and records that read fine but never yield understanding
surface as the *residue* pile. A **Conservator** agent writes per-pile diagnoses and treatment
proposals for collections staff (the probe's stated remediation is ground truth; the agent
augments, never invents). Resolution is measured — a repaired record passes its next survey and
leaves its pile. `rake enliterator:survey` runs the initial inventory.

The compounding rung is proven in the test suite: `spec/services/enliterator/tending/visitor_spec.rb` asserts that the second LLM call receives the first visit's claim in its `state`, and that an UPDATE supersedes the prior claim while preserving the provenance chain.

The collection also knows its own **gaps** (v0.46 — `config.record_lacunae`): when a *required*
term comes back unmet, the engine stops writing a contentless empty claim and opens a **lacuna** — a
named known-unknown (the negative space of a claim), refreshed each beat it stays missing and closed
the day a later visit supplies the value. As of **v0.46.1** the gap is also *diagnosed* — the model
reports, through an `absences` channel, *why* the term is unfillable: `defective_surrogate` (the fact
is in the item but extraction lost it), `silent` (the item omits it; an authority may know), or
`not_identified` (unrecoverable). The epistemic triad: frontier (unknown-unknown) / lacuna
(known-unknown) / claim (known-known). Surfaced as a record-page "Known gaps" panel, a Status rollup,
`rake enliterator:lacunae`, and the `lacunae` MCP tool. Off by default ⇒ byte-identical.

## Quick start

Add the engine to the host Gemfile and mount it.

```ruby
# Gemfile
gem "enliterator"
gem "aws-sdk-bedrockruntime"   # only if using the Bedrock LLM adapter
gem "openai"                   # only if using the OpenAI embedder adapter
```

Run the engine's migrations into the host (they're appended automatically; the
engine owns its pgvector enablement):

```bash
bin/rails db:migrate
```

### Mounting the UI (v0.6)

Mount the engine in the host's routes to get ten web surfaces (twelve with the reference
desk's optional features enabled) — a **status
browser**, a **catalog** (browse and search the enliterated holdings — semantic search
through the retrieval pool, subject-heading browse over the vocabulary in use, and a
"wander" link for open-stacks serendipity), a **conversation UI** (with a scope banner
naming the active context), a **governed-vocabulary review queue**, a **claim
quality-review queue** (the audit's human anchor), a **context tree**, an **atlas**
(the collection drawn as a graph — records, the entities their claims name, every edge
carrying its provenance and asserted-at date; an Overview lens for orientation and an
**Ego lens** to explore around one record or entity — a ranked neighbor list beside the
graph, an inspector showing a node's claims, provenance, and known gaps, and typed-edge
filters by relation, confidence, audit, and depth; replay it to watch the collection
learn, or export a self-contained HTML copy with `rake enliterator:atlas`), a **heartbeat
pulse monitor** (trigger one tending cycle and watch it live), an **About explainer**,
and a **Settings** surface — plus, when the reference desk's optional features are enabled,
a **persona editor** for the desks (versioned, with rollback and reset-to-seed) and a
**conversations** browser (retained, replayable exchanges) —
all styled by one inline component system (no asset pipeline, no style dependency) — for free:

```ruby
# config/routes.rb
mount Enliterator::Engine => "/enliterator"
```

- `/enliterator/` — status browser: per-facet health (the smoke alarm in the browser),
  claim-key vocabulary with samples, the connection graph, vocabulary-gap suggestions, and
  per-record drill-down at `/enliterator/status/<Type>/<id>` — including **"Understanding over
  time"** (v0.14): once a facet has been visited more than once, a visit-by-visit table of every
  claim with changed cells highlighted — the compounding, visible. Programmatic access via
  `Enliterator::Trajectory` (`state_at` any past moment, per-facet diffs with churn detection,
  `compounding_summary` rollups) and `Enliterator::Trajectory::Judge` (blind pairwise LLM
  comparison of a record's earlier vs later understanding).
- `/enliterator/catalog` — the catalog (v0.24): the OPAC over the enliterated holdings.
  Search by meaning (the same embedding pool Chat retrieves from, distances shown), browse
  by **subject heading** (the claim vocabulary in use, counts congruent with their
  click-throughs), filter by type, page the stacks in accession order — every card shows
  the record's understanding (claims, tending depth, contexts) and links to its full entry.
  `/enliterator/catalog/wander` opens a random record: the open-stacks gesture.
- `/enliterator/chat` — a reference interview with the enliteration: answers stream
  token-by-token, grounded in a collection self-portrait plus the records retrieved per
  question, with source chips linking back to the status browser. With
  `config.chat_federation` enabled (v0.28, opt-in), the chat becomes an agentic
  **Reference Desk** — a Frontdesk that triages and routes to grounded specialists, a
  governed loop that enforces the allow-list and shows every tool call inline as a
  provenance widget, and handoff events so the patron sees which desk is answering.
  In **v0.29** that desk is made *legible*: a federated turn reads top-to-bottom as a
  narrative — a **live work-trace** (one row per tool call, status animating spinner → ✓,
  human labels, each tool's structured widget tucked into a `<details>`), then the
  **answer**, then a **"Sources consulted" rail** linking each consulted record to its
  status entry. The prose carries **inline numbered citation chips** (hover → a popover
  with the record's label and type, click → the record). A handoff is a visible divider
  plus a non-destructive scope-banner update. The composer autosizes, submits on Enter
  (Shift+Enter for a newline), shows a typing indicator, and offers follow-up suggestions
  (made agent-reasoned in v0.35 — see below). The whole engine also lifts into a scholarly
  visual register in v0.29 — system-serif display headings, restrained depth, and a shared
  stat-strip across Status / Catalog / Atlas / About / Chat — with no CDN, npm, gem, or
  web-font added (100% inline vanilla, the standing hard rule). Federation OFF emits none of
  the trace/widget/citation DOM or JS; the single-shot stream contract is byte-identical and
  guarded by a regression spec. When a turn fails, **v0.30** replaces the bare error
  bubble with an actionable error card: in development (and only where
  `config.error_detail` permits) it names the exception, where it happened
  (stage · agent · tier), and a hint for the likely fix — an expired AWS SSO session,
  a slow tier, an unreachable gateway. In production the card carries only a generic
  message; detail never leaks. From **v0.31 on** the desk became fluent and tendable: the
  chat chrome recedes once a conversation starts, with a live "Working… Ns" indicator while
  the desk thinks (v0.31); a consulted record becomes a clickable door back into the
  conversation (v0.32); the **agentic answer streams token-by-token** — the loop assembles
  tool-calls from the stream so grounding survives (v0.33) — the page follows the stream and
  the sources rail collapses to a closed `<details>` (v0.34). The desk **reasons its own
  follow-up questions** from the answer it just gave, rendered as clickable next questions
  (v0.35, opt-in via `config.chat_followups`). Its **voice is governable**: an engine-owned
  institutional **register** sits beneath each desk's **persona** (v0.36), and that persona is
  curator-editable, versioned, rollback-able, and resettable to its registered seed on a
  `/enliterator/desks` surface (v0.37 + v0.41, `config.chat_persona_editing`) — the same
  authority control the vocabulary uses, *code seeds, the store governs* — and it is safe to
  hand over because the **loop, not the prompt, enforces** grounding, the read-only allow-list,
  and provenance. Every conversation is **retained as a first-class artifact, replayable from
  its own event stream** (v0.39, `config.chat_retention`) and browsable at
  `/enliterator/conversations`, so a good answer can be shown again with zero model spend and
  the desk's own conversations can, in time, be tended; a desk can also be evaluated without a
  browser (`Chat::Eval` / `rake enliterator:ask`, v0.38). The public accountless desk (Plan B —
  sessionless, link-token, rate-limited) is the forthcoming horizon.
- `/enliterator/suggestions` — the governed-vocabulary review queue: when the model proposes a
  term a facet's contract doesn't cover, a curator approves it, maps it onto an existing key
  (a synonym), or rejects it. The ontology tends itself. The queue ranks by accumulated **pressure**
  and flags **resurged** keys (re-proposed after a verdict). The **"Consider all requests"** button
  (or `bin/rails enliterator:consider`) runs the considerer agent — it reads the field in batches
  (`considerer_batch_size`, so a large queue never overruns the LLM timeout), auto-applies the safe
  verdicts (synonym maps, confident rejects), and leaves approvals for you. The web run is **async**
  (v0.49): the button returns immediately and a live monitor polls until it converges — no blocked request.
  In **v0.9** the loop *converges* (see below): an approved key goes **live** in the effective
  contract immediately (the diff lets you codify it permanently), and a re-proposal of an
  already-resolved key is **suppressed** — counted under "Re-proposed after a verdict" rather than
  re-flooding the queue. Wire `enliterator:consider` after `enliterator:tend` in your scheduler.
- `/enliterator/about` — the explainer (v0.10): what enliteracy is, why the collection is tended, and
  how compounding attention changes it now and over time. The demo surface and a living north-star doc
  (hand-revised each version); a live strip shows real counts from the collection it's mounted on.
- `/enliterator/contexts` — the context tree (v0.13): **nested enliterated collections**. A context
  is a lens — an item belongs to the whole collection and to any number of labeled sub-collections;
  each context declares its own facets (inheriting its ancestors'), claims live per context and read
  cumulatively, neighbors/retrieval are scoped to the context's members, and vocabulary governance is
  per context. A nav switcher views EVERY surface through the selected context (hidden until a tree
  is seeded — flat installs are unchanged). Declare per-context facets with the policy's
  `context "key" do … end` blocks; seed `Enliterator::Context` (ancestry) + memberships
  (`record.place_in_context!`); tend with `enliterator:tend_context CONTEXT=key`.
- `/enliterator/settings` — the configuration surface (v0.11): a read-only window onto the org chart
  (facets → tiers, the climb, required keys), the effective vocabulary per facet (code + accrued
  `live` keys), routing/capability, the considerer's autonomy, and tending behavior. Reflects the
  code config; the approved vocabulary that accrues at runtime is governed on `/enliterator/suggestions`.

The UI is self-contained (inline CSS/JS, no asset-build step) and renders under any host
pipeline. The conversation tier defaults to the staffing ladder's top tier; pin it with
`config.conversation_tier` in the initializer. Wrap the mount in the host's auth as needed.

Make a model tendable:

```ruby
class Document < ApplicationRecord
  include Enliterator::Tendable

  # Host SHOULD provide the text representation used for embedding + tending.
  def to_enliterator_text
    [title, summary, body].compact.join("\n")
  end
end
```

Tend a record:

```ruby
doc = Document.find(id)
doc.tend!(facet: "summary")          # runs one Visitor pass synchronously
Enliterator::TendingVisitJob.perform_later(doc, "summary")  # …or in the background
```

Deep-read a record (v0.25 — **analytical cataloging**): give the host a
`to_enliterator_parts` method (`[{heading:, text:}]` in document order) and declare an
`analysis` facet with `scheduled: false` (fully staffed, never planned by the heartbeat —
readings run by deliberate invocation). `Tending::Reading` then works the way a librarian
reads a dense work: section it, take per-section notes (each part is a first-class tendable
— claims, escalation, audits, embeddings all apply), and re-tend the work-level facets from
the assembled notebook so the deepening supersedes the front-matter understanding in place:

```ruby
Enliterator::Tending::Reading.new(doc, context: ctx,
                                  synthesizes: %w[summary significance]).call
# => { parts: 23, tended: 23, skipped: 0, failed: 0, synthesized: 2, tokens: 124_718, ... }
```

Unchanged sections are skipped on re-reads (re-reading an unchanged section is pure NOOP
spend); part claims are audited against their own section's text; `Trajectory::Judge` can
blindly compare the shallow vs deep understanding before you commit to a whole-collection
campaign.

### The MCP surface (v0.26)

The engine speaks the Model Context Protocol natively — `POST /enliterator/mcp`, the
protocol minimum implemented inline (JSON-RPC 2.0 over POST, tools only, no gem, no SSE).
Wire a conversational agent up with:

```
claude mcp add --transport http enliterator https://your-host/enliterator/mcp
```

Fourteen tools, designed around what an enliterated collection uniquely offers an agent —
**provenance, trajectory, and self-knowledge**: `collection_overview` and `vocabulary`
(orient), `search` / `browse_subjects` / `subject_search` / `record_entry` (navigate — every
claim carries its confidence, tier, and audit verdict), `connections` (the Atlas,
queryable), `trajectory` ("what did the collection learn, and when?"), `provenance` ("how
do you know that?"), `quote` (claim → the located source passage), `accuracy` (the audited
rates, so the agent can calibrate out loud), `recent_activity` (the diary — "how did last
night's tending go?" as one call; `rake enliterator:brief` is the same digest for a
terminal) — plus two **governed writes**: `propose_term`
files into the authority-control queue and `flag_claim` files an agent audit into the
review queue. The agent is another patron and another set of eyes — never a hand that
edits the record: agent flags change no accuracy number (instrument-scoped, spec-pinned).
Every response is bounded (caps + truncation flags) and self-describing (`next:` hints).

`rake enliterator:deployment` prints the live deployment profile — mode and gateway
readiness, the full config, the staffing ladder/tiers and every facet (root + per-context)
with its tier and scheduled flag, tendables, contexts, and the last beat with an inferred
cadence — and it names what it *cannot* introspect (the schedule, log paths — those belong to
the host scheduler), pointing to the host's `doc/enliterator/deployment.md`. The engine
describing its own shape, so a status check reads the system instead of guessing
(`FORMAT=json` for the raw hash).

`rake enliterator:first_impression` (v0.58) measures the whole point in one number: how much a
record's enliteration adds to a machine reader's *first impression* over the bare surrogate a
catalog gives it. It samples records in a context, generates a grounded question set per record,
answers it under four reading conditions — the abstract alone, a catalog record, the abstract +
the enliteration, and (opt-in) the raw full source — blind-grades, and reports the coverage and
reliability *lift*, with a reading-accuracy canary that flags if a question leaked into the wrong
condition. The finding-aid thesis, made falsifiable: *capability moves inference, not contact* — the
enliteration helps most exactly where a stronger model can't reach the missing knowledge itself.

Inspect the accumulated literacy:

```ruby
doc.literacy_state(facet: "summary")
# => { claims: [...], recent_visits: [...], measures: {"completeness" => 0.66} }

doc.enliterator_claims.live           # current, non-superseded understanding
doc.last_tended_at(facet: "summary") # newest succeeded visit's finished_at
```

With no adapters configured the engine falls back to **Null** adapters — inert
and deterministic, safe for tests, network-free. Production must configure real
adapters (below); the Null LLM produces no claims and the Null embedder produces
a deterministic pseudo-vector.

## The `Enliterator.configure` DSL

Configure once in a host initializer (`config/initializers/enliterator.rb`):

```ruby
Enliterator.configure do |c|
  # LLM substrate. nil => Null adapter (inert). Bedrock reads its model id from
  # the host — model ids change, so none is hardcoded in the engine.
  c.llm_adapter = Enliterator::Adapters::LLM::Bedrock.new(
    model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0", # region-prefixed inference profile id
    region:   ENV.fetch("AWS_REGION", "us-east-1")
  )

  # Embedding substrate. nil => Null adapter. OpenAI defaults to
  # text-embedding-3-small (1536d) to match HSDL's vector(1536) columns.
  c.embedder_adapter = Enliterator::Adapters::Embedder::OpenAI.new

  c.default_embedding_dimensions = 1536      # vector width for the embeddings table
  c.tending_facets = [:summary]             # named lanes; each its own prompt/cadence
  c.tend_batch_size = 50                      # max records the scheduled walk enqueues per model/facet/run
  c.stale_after     = 90.days                 # re-tend records whose newest visit is older than this
  c.queue_name      = :enliterator            # ActiveJob queue for TendingVisitJob
  c.logger          = Rails.logger            # optional; defaults to Rails.logger
  c.error_detail    = nil                     # chat error cards: nil = auto (dev only), true/false to force

  # Reference Desk (the agentic chat surface) — all opt-in; byte-identical to single-shot when off:
  c.chat_federation      = false              # agentic loop + grounded specialists (else single-shot chat)
  c.chat_followups       = false              # the desk reasons clickable follow-up questions
  c.chat_register        = nil                # engine-owned institutional voice (nil => the default register)
  c.chat_persona_editing = false              # mount /desks: curator-edit personas (versioned, rollback, reset)
  c.chat_editor          = nil                # callable(request) => editor identity for persona versions
  c.chat_retention       = false              # persist + replay conversations; mount /conversations
  c.chat_sources         = false              # emit a structured :sources event so a host can link/deliver consulted records

  # Name authority control — canonicalize person-name claim values (advisor, author):
  c.name_authority_keys  = []                  # name-bearing keys; [] = off (byte-identical). Then: rake enliterator:reconcile_names
end
```

| Setting | Default | Purpose |
|---------|---------|---------|
| `llm_adapter` | `nil` → `LLM::Null` | the language model that interprets and reconciles |
| `embedder_adapter` | `nil` → `Embedder::Null` | turns text into vectors for neighbor search |
| `default_embedding_dimensions` | `1536` | width of the `vector` column / HNSW index |
| `tending_facets` | `[:summary]` | named tending lanes the scheduled walk iterates |
| `tend_batch_size` | `50` | per model/facet cap on records enqueued per run (no silent truncation — a cap hit is logged) |
| `stale_after` | `90.days` | staleness threshold for the scheduled walk |
| `queue_name` | `:enliterator` | queue `TendingVisitJob` enqueues onto |
| `error_detail` | `nil` (auto) | actionable detail in chat error cards: `nil` = on in dev only, `true`/`false` to force. Detail (exception, where, fix-hint) **never reaches production** unless forced; the gate is server-resolved (no request param enables it) |
| `chat_federation` | `false` | turn the chat into the agentic **Reference Desk** (triage + grounded specialists, a governed loop); off = single-shot grounded chat |
| `chat_followups` | `false` | the desk reasons up to three clickable follow-up questions from its own answer |
| `chat_register` | `nil` | the engine-owned institutional voice beneath every persona (`nil` => the default register) |
| `chat_persona_editing` | `false` | mount `/desks` — curator-edit each desk's persona, versioned with rollback + reset-to-seed |
| `chat_editor` | `nil` | callable `(request) => editor` attributing persona versions; auth-agnostic (rescued) |
| `chat_retention` | `false` | retain conversations as replayable artifacts; mount `/conversations` to browse + label |
| `chat_sources` | `false` | emit a structured `:sources` event after each record-bearing tool call (`{type, id, label}`, host-agnostic — never a URL) so a federated host can resolve catalog links / deliver files; the governed desk stays read-only (it only surfaces) |
| `name_authority_keys` | `[]` | claim keys whose values are person names (e.g. `advisor`, `authored_by`) put under **name authority control** — variant spellings of one person resolve to a canonical form in Catalog counts + the Atlas. `[]` = off (byte-identical). Populate with `rake enliterator:reconcile_names` |

Adapters are POROs and accept an injected `client:` so they can be stubbed in
specs with no network and no provider gem. Provider gems are lazy-required inside
the adapter; a missing gem raises `Enliterator::ConfigurationError` with an
actionable message rather than failing at boot.

## How the tending loop works

`Enliterator::Tending::Visitor#call` is the compounding contract. One Visitor
instance performs one pass over one record along one facet:

1. **Open a Visit** (`status: "running"`, `model:`, `prompt_version:`,
   `started_at:`). The `enliterator_visits` table is immutable history — the PROV
   Activity spine. Nothing is ever overwritten; a failed pass is recorded as a
   `failed` visit and re-raised.
2. **Read prior understanding** via `literacy_state(facet:)`: the record's live
   claims, its five most recent visits on this facet, and its current measure
   scores. *This is the step that makes it compound* — the next interpretation is
   conditioned on the last.
3. **Gather corpus neighbors** from the record's `"primary"` embedding (the five
   nearest by cosine distance, excluding self). If the record isn't embedded yet,
   neighbors are gracefully empty and `input_refs[:neighbor_ids]` records that.
4. **Ask the model** (`llm.tend(text:, facet:, state:, neighbors:)`) for
   structured claims, each with an `op` (ADD/UPDATE/DELETE/NOOP) and a confidence.
   The adapter forces structured output (Bedrock binds a single `emit_claims`
   tool to the response schema).
5. **Reconcile** the proposed claims against the existing live claim store
   (below).
6. **Finalize the Visit** (`status: "succeeded"`, `raw_response`,
   `reconciliation`, `confidence`, `input_refs` — `{prior_visit_ids, neighbor_ids,
   claim_keys}` — `tokens`, `duration_ms`, `finished_at`).
7. **Recompute measures** for the record.

### Reconciliation (the mem0-style ADD/UPDATE/DELETE/NOOP contract)

Each proposed claim is matched to the current live claim for its `key`:

- **ADD** (no live claim for the key) → create a `draft` Claim, attributed to the
  model, generated by this visit.
- **UPDATE** (live claim exists, not locked) → create a *new* Claim, set its
  `derived_from` to the old claim, and call `old.supersede!(new)`. The old claim
  is marked `superseded` and points to its replacement, so the provenance chain
  is preserved end to end.
- **UPDATE on a locked claim** → **NOOP**. A `locked` claim is a curator anchor
  and is never auto-superseded.
- **DELETE** (live claim, not locked) → tombstone it (`status: "superseded"`, no
  replacement).
- **NOOP** → recorded, nothing changes.

When `op` is absent it defaults to UPDATE if a live claim exists for the key,
otherwise ADD. Reconciliation returns `{added:[], updated:[], deleted:[],
noop:[]}` (terms), stored on the Visit.

### Measures

`Enliterator::Measures` is a registry of weighted-signal quality scorers (the HSDL
RecordQuality pattern). The engine ships one default, `:completeness`, scoring
the fraction of an expected set that's present: has a live claim, has a primary
embedding, has a succeeded visit. Hosts register richer measures (HSDL maps its
12-signal health score here):

```ruby
Enliterator::Measures.register(:health) do |tendable|
  signals = { recency: { value: ..., weight: 0.3 }, ... }
  { score: weighted_sum(signals), signals: signals }
end
```

`Enliterator::Measures.recompute!(record)` runs every registered measure and upserts
one `Measure` row per `[record, name]`.

### The heartbeat (v0.15 — event-driven, not wall-clock)

`rake enliterator:heartbeat` runs one full metabolic cycle: **plan → tend →
consider → ledger**. The planner (a pure read) computes a budget-bounded queue
from signals already in the tables — a change envelope (20% by default:
source-change, then neighborhood — context-mates tended since a record's last
visit, the trigger v0.14 *measured* — then vocabulary approvals), the untended
**frontier** (where first attention earns ~10× the claims per token), and a
demoted `stale_after` sweep that gets only leftovers. Sync mode (the default)
enforces the budget on **actual** tokens; every cycle is a `Heartbeat` row and
every visit it causes carries `heartbeat_id` + `reason` — the schedule is
auditable provenance, not a cron log. `PLAN=1` dry-runs the queue and prints the
frontier horizon ("N records remaining ≈ M cycles at this budget"). The browser
trigger (`/enliterator/heartbeat`) shares one guard: its budget box clamps **down**
to `config.heartbeat_budget_tokens` (a stray zero can't authorize a mega-cycle) and
now says so — the form names the ceiling, warns live when you type past it, and the
post-beat notice reports any clamp (v0.57.2).

A cycle also degrades gracefully through **transient bedrock unavailability**
(v0.41.1). All enliteration runs on a Bedrock credit with no fallback, so an
expired AWS SSO session *or* a gateway timeout is treated as a **pause**, not a
failure: the affected records are **deferred** (left on the frontier, no Visit),
the considerer holds the scopes it can't reach (the ones it finished stay saved),
and the cycle finishes clean (exit 0) so the deferred work resumes on the next
beat (after `aws sso login` if the token lapsed). A real fault — bad request,
model-not-found, a bug — still stays fatal.

```
PLAN=1 bin/rails enliterator:heartbeat        # read the plan first
BUDGET=30000 bin/rails enliterator:heartbeat  # a small supervised cycle
ENQUEUE=1 bin/rails enliterator:heartbeat     # production: TendingVisitJobs
```

The pre-v0.15 `rake enliterator:tend` walk (stale_after batches) still works
unchanged for hosts that prefer it. The job is `retry_on StandardError`
(polynomial backoff, 3 attempts) and `discard_on
ActiveJob::DeserializationError` (the record was deleted between enqueue and run).

Failure states are managed (v0.23): every cycle ends on the ledger. The row
pulses liveness + its current phase through every loop; a cycle whose process
dies (server restart mid-cycle) is **reaped** — finished_at set to its last
sign of life, the death phase named, `executed` reconstructed from the visit
record — and a zombie thread of a reaped cycle stands down instead of
double-spending. Gateway calls are bounded (`gateway_timeout`, default 180s).

### Portability (v0.22 — move the enliteration, don't re-buy it)

Everything the engine has learned is spent inference and curation; a fresh
deployment should inherit it. `rake enliterator:export FILE=enliteration.tar`
writes one archive (manifest + per-table PostgreSQL binary COPY streams —
claims with their provenance chains, visits, the ratified vocabulary, audits,
embeddings). On the target: `rake enliterator:import FILE=...` (refuses a
non-empty target; `FORCE=1` replaces), ids preserved, sequences continuing
after the imported history. The condition register deliberately stays home —
it must describe the *target's* files; run `enliterator:survey` there.
Deploying a host app for the first time? The checklist: push/bundle the engine
version the initializer expects, wrap the mount in auth, set the gateway key,
adopt a scheduler for the heartbeat, then import the enliteration.

## Staffing & Routing

Routing is not a config knob — it is a first-class **org chart**. A tending
**facet is a ROLE**; a LiteLLM **alias is a capability TIER**;
`Enliterator::Staffing::Policy` is the policy that maps roles to tiers, defines
the escalation ladder, and enforces constraints. Deciding *how much mind to bring
to a record* in a given state IS the curatorial act.

The routing target is the **LiteLLM gateway** (`https://llm.example.com/v1`,
OpenAI-compatible). Tiers are aliases (`cheap`, `quality`, `embed`, …); the
gateway owns provider/fallback/load-balancing/cost. The engine names intent (an
alias) and tags the call — it never names a provider.

```ruby
Enliterator.configure do |c|
  c.gateway_base_url = "https://llm.example.com/v1"   # default
  c.gateway_api_key  = ENV["LITELLM_KEY"]          # project key, from ENV — never committed
  c.staffing = Enliterator::Staffing::Policy.new do
    assign :summary, tier: "cheap"                 # facet → tier (role → capability)
    embedding_tier "embed"
    ladder ["cheap", "quality"]                    # escalation order, junior → senior
    escalation_threshold 0.6                        # escalate below this confidence
    max_promotions 1                                # bound the climb
    verify_floor "quality"                          # min tier permitted to mint `verified`
    on_prem_tiers ["cheap"]                          # tiers that never route off-prem
  end
end
```

**The loop, with escalation.** `tier_for(facet)` picks the starting tier;
`allowed_tiers(tendable, facet)` clamps the ladder by constraints. The Visitor
runs a visit at the tier, and while the result is low-confidence (or the model
self-flags `escalate`), a higher allowed tier exists, and `escalation_step <
max_promotions`, it **escalates** — handing the junior tier's proposed claims to
the senior as `state["proposed_by_lower_tier"]` so the senior *reviews the
junior's draft*. Only the **final tier's visit reconciles and writes claims**;
junior visits are recorded as provenance only (`applied: false`), linked by
`escalated_from_id`. Each Visit records its `tier` and `escalation_step`.

**verify_floor** keeps a cheap pass from poisoning the compounding well: a claim
may be minted `verified` only when the writing tier is at/above the floor **and**
the model asserted it. Below the floor, claims stay `draft` regardless of
confidence.

**Constraints.** A tendable answering `enliterator_on_prem_only? => true` has its
ladder clamped to `on_prem_tiers` and never routes off-prem, even on escalation.
`validate!(available_aliases)` (against `GET /v1/models`) fails fast at boot if
the policy names an unknown alias. When the host configures no staffing,
`Policy.default` routes every facet to a single tier so the engine still runs.

**Back-compat.** Injecting `llm:` into the Visitor (the v0.1 path) bypasses
staffing entirely: one visit, direct write, claims `draft`. When `staffing` is
unset and no gateway key is present, `Enliterator.llm(tier:)` falls back to the
v0.1 single adapter.

**Spend.** Every gateway request carries `metadata: {tags: [...]}`
(`["enliterator", "host:<host>", "facet:<facet>", "tier:<tier>", "esc:<step>",
"record:<Class>/<id>"]`) — the join key to LiteLLM's authoritative dollars.
`Enliterator::Spend.by_facet(host:, since:)` is the engine's own local ledger,
grouping `Visit.tokens` by facet and tier (with an optional price map → $).

## Facet Contracts & Suggestions

A facet with no output contract lets the model freelance terms — `author`
vs `authored_by`, redundant `institution`/`date`. Key drift breaks reconciliation
(a re-tend ADDs a duplicate instead of UPDATEing) and so corrupts compounding at
scale. The fix is **both** a controlled vocabulary **and** a sanctioned channel to
propose additions: the ontology itself becomes a tended, governed thing.

**Controlled terms.** Declare a facet with `facet(name, tier:, terms:)` — the
contract-bearing sibling of `assign`. It sets the tier exactly as `assign` does,
**and** binds the allowed-term vocabulary:

```ruby
Enliterator.configure do |c|
  c.staffing = Enliterator::Staffing::Policy.new do
    facet :metadata, tier: "quality", terms: {
      author: "Who authored the work.",
      date:   "When the work was created."
    }
    assign :summary, tier: "cheap"   # NO terms => unconstrained (open vocabulary, v0.2)
    ladder ["cheap", "quality"]
  end
end
```

When a facet has a contract, the Visitor threads it into the adapter's `#tend`:
the structured-output schema enums each claim `key` to the allowed set and the
system prompt gains a CONTROLLED VOCABULARY block. After parse, the Visitor
reconciles **only** claims whose key is in the vocabulary (off-list keys are
dropped — the enum should already prevent them; this is the safety net).

**The suggestion loop.** The schema also advertises an optional top-level
`suggestions` array. When the model observes something no allowed key covers, it
does **not** invent a key — it proposes one: `{proposed_key, rationale,
example_value}`. The Visitor persists each as an `Enliterator::Suggestion` with
full provenance (tendable, facet, final tier/model, final visit) and fires
`config.suggestion_sink` per row (a callable for forwarding to a shared vocabulary
tracker — KN, a review queue — default `nil`, local-only).

A human renders the verdict — `approve!(note:)`, `map!(note:)` (a synonym of an
existing key), `reject!(note:)` — and `Enliterator::Suggestion.gaps(facet: nil)`
aggregates open proposals into a **demand-ranked** report (which keys are asked for
most often, across how many distinct records, with a sample rationale/example) so
the vocabulary can be tended where it is actually too narrow.

**`assert_claim!` — host metadata as locked claims.** Some facts the LLM should
never derive: an authoritative `published_at`, an institution pulled straight from
the source record. `tendable.assert_claim!(key:, value:, locked: true, status:
"verified", attributed_to: "host")` seeds (or in-place upserts) such a fact as a
first-class, **locked**, verified Claim — idempotent, and it creates no Visit
(this is import, not tending). Because reconcile NOOPs locked claims on UPDATE, a
host-asserted claim survives all subsequent tending untouched.

**Back-compat.** Every contract behavior is gated on a contract being present.
A facet declared with `assign` (or never declared) is unconstrained: open keys,
no suggestions emphasis, default `RESPONSE_SCHEMA` — byte-identical to v0.2. The
injected-`llm:` (v0.1) path threads no contract at all.

**The converging cycle (v0.9).** Earlier, a verdict didn't change what the model
saw, so the next tend re-proposed the same synonyms and the queue never settled.
v0.9 makes the loop reach a fixed point:

1. **`enliterator:tend`** walks records; the model proposes keys the contract misses.
2. **`enliterator:consider`** reads the whole field and renders verdicts — auto-mapping
   synonyms and rejecting noise, holding genuine new concepts for your approval.
3. The **next `enliterator:tend`** sees the *effective* contract — `Enliterator::Contract.for(facet)`
   = code keys **+ approved keys** — so an approved key is emitted as a **claim**, not re-proposed;
   and a re-proposal of an already-mapped/rejected key is **suppressed** (counted under "Re-proposed
   after a verdict", not re-filed).

Each lap the open field shrinks toward the genuinely contested terms instead of
re-presenting the whole backlog. The effective contract is *derived from explicit
approval verdicts* (auditable; code keys always win a name conflict), and the
"Approved & live — codify in your policy" diff lets you fold any live key back into
the versioned policy permanently — after which the DB derivation for it is redundant.
Disable the live-extension behavior with `config.apply_approved_keys = false` (then
only code-defined keys are ever in force).

**Read-time warrant accrual (v0.41.2 — `config.read_time_warrant`, default off).**
The converging cycle above ratifies *centrally* (the considerer reads the whole
field). But convergence should also begin *where the reading happens* — otherwise
every reader proposes blind, each coining its own synonym (`issuing_organization` /
`issuing_agency` / `organization_origin`), and the considerer inherits a fragmented
field. With `read_time_warrant` on, the Visitor threads a **candidate block** into
`#tend` beside the controlled vocabulary: the bounded, demand-ranked set of *open*
candidate terms other readers have proposed for this facet/context
(`Enliterator::Vocabulary.candidates_for`, read off live `Suggestion.gaps` so a key
proposed earlier in the same cycle is already visible). The instruction is
three-tier — use an *established* term as a claim key; **affirm** a *candidate* that
fits by re-proposing its `proposed_key` (warrant accrues through the existing
Suggestion machinery, no new storage); propose a *novel* key only when neither fits.
Affirmation collapses synonyms at the source — warrant becomes the breadth of
distinct records that recognize a term — so the considerer ratifies a small,
genuinely-warranted field. Off ⇒ byte-identical (no candidate retrieval, no prompt
change).

## Architecture notes

- **Polymorphic ids are strings.** Every `*_id` column on engine tables is
  `:string` so a host with UUID primary keys (HSDL's `doc_meta.id`) and a host
  with bigint keys both work without schema changes.
- **Multiple named embeddings per record.** The unique
  `[embeddable_type, embeddable_id, kind]` index lets one record carry e.g. a
  `"primary"` and a `"full_text"` vector. `content_hash` (SHA256 of the embedded
  text) lets the host skip re-embedding unchanged text.
- **The engine owns pgvector.** A migration enables the extension; the embeddings
  table carries an HNSW cosine index (`vector_cosine_ops`).
- **Table prefix `enliterator_`, namespace `Enliterator`.** Isolated namespace; no
  collisions with host tables.

## Deferred

Out of scope (deliberately not built):

- **Entity / relationship knowledge graph** — HSDL already has one; Enliterator
  tends records and *draws* the entity-bearing claims as the Atlas graph (v0.21),
  but it does not maintain a separate cross-record entity/relationship model.
- **Slack / external notification workflow** — in-app human-in-the-loop review
  exists (the `/suggestions` authority-control queue and the `/review` audit anchor),
  but pushing approvals out to Slack or email is not built.
- **Dynamic per-host scheduler UI** — the heartbeat can be triggered and watched in
  the browser, but per-host cadence/facet/tier configuration is still code, not UI.
- **Input chunking for small-context tiers** — over-window inputs escalate to a
  larger-context tier rather than being chunked (analytical cataloging, v0.25, reads
  a work section-by-section, the deliberate path for long works).
- **Public accountless desk (Plan B)** — the agentic Reference Desk is account-gated;
  a sessionless, link-token, rate-limited public desk is the named horizon.

Implemented in v0.2 (was deferred in v0.1): **routing / staffing** — facet→tier
assignment, the escalation ladder, `verify_floor`, on-prem constraints, the
LiteLLM gateway adapter, and per-loop spend attribution (see *Staffing & Routing*
above).

## Development

```bash
bundle install
bundle exec rspec     # 717 examples, 0 failures (Null/stub adapters; no network)
```

The test host app lives in `spec/dummy` (a `Widget` model that includes
`Enliterator::Tendable`). Specs use the Null/stub adapters exclusively — no AWS,
no OpenAI, no network.

## License

Available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
