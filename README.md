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
| 4 | **tended** | understanding is maintained, not abandoned | scheduled `enliterator:tend` walk + `TendingVisitJob` re-visit stale records |
| 5 | **compounding** | each visit improves on the last | the Visitor hands prior claims + recent visits into the next visit's context; claims are reconciled (ADD/UPDATE/DELETE/NOOP), not overwritten |

The compounding rung is proven in the test suite: `spec/services/enliterator/tending/visitor_spec.rb` asserts that the second LLM call receives the first visit's claim in its `state`, and that an UPDATE supersedes the prior claim while preserving the provenance chain.

## Quick start

Add the engine to the host Gemfile and mount it. (HSDL also needs the provider
gems — see [HSDL_ADOPTION.md](HSDL_ADOPTION.md).)

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
doc.tend!(stream: "summary")          # runs one Visitor pass synchronously
Enliterator::TendingVisitJob.perform_later(doc, "summary")  # …or in the background
```

Inspect the accumulated literacy:

```ruby
doc.literacy_state(stream: "summary")
# => { claims: [...], recent_visits: [...], facets: {"completeness" => 0.66} }

doc.enliterator_claims.live           # current, non-superseded understanding
doc.last_tended_at(stream: "summary") # newest succeeded visit's finished_at
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
  c.tending_streams = [:summary]             # named lanes; each its own prompt/cadence
  c.tend_batch_size = 50                      # max records the scheduled walk enqueues per model/stream/run
  c.stale_after     = 90.days                 # re-tend records whose newest visit is older than this
  c.queue_name      = :enliterator            # ActiveJob queue for TendingVisitJob
  c.logger          = Rails.logger            # optional; defaults to Rails.logger
end
```

| Setting | Default | Purpose |
|---------|---------|---------|
| `llm_adapter` | `nil` → `LLM::Null` | the language model that interprets and reconciles |
| `embedder_adapter` | `nil` → `Embedder::Null` | turns text into vectors for neighbor search |
| `default_embedding_dimensions` | `1536` | width of the `vector` column / HNSW index |
| `tending_streams` | `[:summary]` | named tending lanes the scheduled walk iterates |
| `tend_batch_size` | `50` | per model/stream cap on records enqueued per run (no silent truncation — a cap hit is logged) |
| `stale_after` | `90.days` | staleness threshold for the scheduled walk |
| `queue_name` | `:enliterator` | queue `TendingVisitJob` enqueues onto |

Adapters are POROs and accept an injected `client:` so they can be stubbed in
specs with no network and no provider gem. Provider gems are lazy-required inside
the adapter; a missing gem raises `Enliterator::ConfigurationError` with an
actionable message rather than failing at boot.

## How the tending loop works

`Enliterator::Tending::Visitor#call` is the compounding contract. One Visitor
instance performs one pass over one record along one stream:

1. **Open a Visit** (`status: "running"`, `model:`, `prompt_version:`,
   `started_at:`). The `enliterator_visits` table is immutable history — the PROV
   Activity spine. Nothing is ever overwritten; a failed pass is recorded as a
   `failed` visit and re-raised.
2. **Read prior understanding** via `literacy_state(stream:)`: the record's live
   claims, its five most recent visits on this stream, and its current facet
   scores. *This is the step that makes it compound* — the next interpretation is
   conditioned on the last.
3. **Gather corpus neighbors** from the record's `"primary"` embedding (the five
   nearest by cosine distance, excluding self). If the record isn't embedded yet,
   neighbors are gracefully empty and `input_refs[:neighbor_ids]` records that.
4. **Ask the model** (`llm.tend(text:, stream:, state:, neighbors:)`) for
   structured claims, each with an `op` (ADD/UPDATE/DELETE/NOOP) and a confidence.
   The adapter forces structured output (Bedrock binds a single `emit_claims`
   tool to the response schema).
5. **Reconcile** the proposed claims against the existing live claim store
   (below).
6. **Finalize the Visit** (`status: "succeeded"`, `raw_response`,
   `reconciliation`, `confidence`, `input_refs` — `{prior_visit_ids, neighbor_ids,
   claim_keys}` — `tokens`, `duration_ms`, `finished_at`).
7. **Recompute facets** for the record.

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
noop:[]}` (claim keys), stored on the Visit.

### Facets

`Enliterator::Facets` is a registry of weighted-signal quality scorers (the HSDL
RecordQuality pattern). The engine ships one default, `:completeness`, scoring
the fraction of an expected set that's present: has a live claim, has a primary
embedding, has a succeeded visit. Hosts register richer facets (HSDL maps its
12-signal health score here):

```ruby
Enliterator::Facets.register(:health) do |tendable|
  signals = { recency: { value: ..., weight: 0.3 }, ... }
  { score: weighted_sum(signals), signals: signals }
end
```

`Enliterator::Facets.recompute!(record)` runs every registered facet and upserts
one `Facet` row per `[record, name]`.

### The scheduled walk

`rake enliterator:tend` iterates every registered tendable model and every
configured stream, finds up to `tend_batch_size` records whose newest succeeded
visit is older than `stale_after` (or that have never succeeded), and enqueues a
`TendingVisitJob` for each. It logs how many were enqueued per model/stream and
flags any batch-cap hit (no silent truncation). Hosts wire this to their
scheduler — HSDL uses sidekiq-cron; a Solid Queue host would use a recurring
task. The job is `retry_on StandardError` (polynomial backoff, 3 attempts) and
`discard_on ActiveJob::DeserializationError` (the record was deleted between
enqueue and run).

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

Out of scope for v0.1 (deliberately not built):

- **Entity / relationship knowledge graph** — HSDL already has one; Enliterator
  tends records, it does not model cross-record entities or relationships.
- **MCP tools** — no Model Context Protocol surface in this version.
- **Slack / expert human-in-the-loop** — the schema supports it (`locked`,
  `review_state`) but no notification or approval workflow is built.
- **Dynamic per-host scheduler UI** — scheduling is a flat rake walk; per-host
  cadence/stream configuration UI is deferred.
- **CE / MoMA adoption** — only the HSDL adoption guide is written.

## Development

```bash
bundle install
bundle exec rspec     # 73 examples, 0 failures (Null/stub adapters; no network)
```

The test host app lives in `spec/dummy` (a `Widget` model that includes
`Enliterator::Tendable`). Specs use the Null/stub adapters exclusively — no AWS,
no OpenAI, no network.

## License

Available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
