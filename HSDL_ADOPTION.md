# Adopting Enliterator in HSDL

This is a **guide**, applied under review. **Adopting Enliterator does not edit
any HSDL production code.** Every change below is additive and lands through
HSDL's normal review process — a Gemfile line, an initializer, a one-line
`include`, a migration, a backfill task, and a cron entry. Nothing in HSDL's
existing enrichment, embedding, or scoring code is modified or removed by the
engine; the engine sits *alongside* what's there and gradually subsumes the
one-shot enrichment pattern with a compounding one.

HSDL's relevant shape (for mapping reference):

- `DocMetum` — the document metadata model, UUID primary key (`doc_meta.id`).
- `enrichment_metadata` — per-run output of HSDL's current one-shot enrichment.
- `health_data` / `health_score` — HSDL's 12-signal RecordQuality scoring.
- `summary_data` — generated summary payload.
- `embedding` (`vector(1536)`) — primary document embedding.
- `full_text_embedding` (`vector(1536)`) — full-text embedding.

Enliterator's polymorphic `*_id` columns are `:string`, so `DocMetum`'s UUID PK
works without any schema accommodation.

---

## 1. Mount the engine

```ruby
# Gemfile
gem "enliterator"
gem "aws-sdk-bedrockruntime"   # Bedrock LLM adapter
gem "openai"                   # OpenAI embedder adapter (HSDL already uses this gem)
```

```bash
bundle install
bin/rails db:migrate   # engine migrations are appended automatically; the engine enables pgvector itself
```

The engine adds five tables — `enliterator_embeddings`, `enliterator_visits`,
`enliterator_claims`, `enliterator_facets` — under its own `enliterator_` prefix.
No existing HSDL table is touched.

---

## 2. Make `DocMetum` tendable

A single additive line. HSDL's existing `DocMetum` code is unchanged:

```ruby
# app/models/doc_metum.rb  (add one include + one text method; nothing removed)
class DocMetum < ApplicationRecord
  include Enliterator::Tendable

  # Text representation used for embedding + tending. Compose from whatever
  # fields HSDL already exposes; this is the only new method required.
  def to_enliterator_text
    [title, abstract, summary_data&.dig("summary"), full_text].compact.join("\n\n")
  end
end
```

`include Enliterator::Tendable` registers `DocMetum` with the scheduled walk and
adds the `enliterator_visits` / `enliterator_claims` / `enliterator_facets` /
`enliterator_embeddings` associations plus `tend!`, `literacy_state`, and
`last_tended_at`.

---

## 3. Configure the substrate

```ruby
# config/initializers/enliterator.rb
Enliterator.configure do |c|
  # LLM: AWS Bedrock (Claude). Model id is region/account-specific — read from the
  # host, never hardcoded in the engine. Use the inference-profile id enabled for
  # HSDL's AWS account.
  c.llm_adapter = Enliterator::Adapters::LLM::Bedrock.new(
    model_id: ENV.fetch("ENLITERATOR_BEDROCK_MODEL_ID",
                        "us.anthropic.claude-3-5-sonnet-20241022-v2:0"),
    region:   ENV.fetch("AWS_REGION", "us-east-1")
  )

  # Embedder: OpenAI text-embedding-3-small (1536d) — matches HSDL's existing
  # vector(1536) columns exactly, so neighbor math is consistent across the two.
  c.embedder_adapter = Enliterator::Adapters::Embedder::OpenAI.new(
    model:   "text-embedding-3-small",
    api_key: ENV["OPENAI_API_KEY"]
  )

  c.default_embedding_dimensions = 1536
  c.tending_streams = [:summary, :health]   # one lane for narrative, one for quality
  c.tend_batch_size = 100
  c.stale_after     = 90.days
  c.queue_name      = :enliterator          # routes onto HSDL's Sidekiq
  c.logger          = Rails.logger
end
```

Production env vars (Bedrock model id, `AWS_REGION`, `OPENAI_API_KEY`) follow
HSDL's standard pattern: append to the server env file (`~/.hsdl-rails.env`),
loaded by systemd / sourced for `rails runner`. `.env` is not loaded in
production — this is expected Rails behavior, not a bug.

Because the adapters accept an injected `client:`, HSDL's own specs can stub them
with no network and no AWS/OpenAI dependency.

---

## 4. Map HSDL's existing data onto Enliterator

The mapping turns HSDL's one-shot artifacts into the compounding structure.
Each maps to exactly one Enliterator concept:

| HSDL field | Enliterator concept | How |
|------------|---------------------|-----|
| `enrichment_metadata` | **Visit** | each historical enrichment run becomes an immutable `enliterator_visits` row (the PROV Activity record of "we read X and produced Y at time T") |
| `health_data` / `health_score` | **Facet** (`:health`) | register a facet that returns HSDL's 12-signal score + signals; the engine upserts one `enliterator_facets` row per record |
| `summary_data` | **Claims** | each summary field becomes a provenanced `enliterator_claims` row keyed by field, reconcilable on future visits |
| `embedding` | **Embedding** kind `"primary"` | one `enliterator_embeddings` row, `kind: "primary"` |
| `full_text_embedding` | **Embedding** kind `"full_text"` | one `enliterator_embeddings` row, `kind: "full_text"` |

### 4a. Register the health facet

HSDL's RecordQuality scoring maps directly onto the Facets registry. Add to the
initializer (after `Enliterator.configure`):

```ruby
# config/initializers/enliterator.rb  (continued)
Enliterator::Facets.register(:health) do |doc|
  data = doc.health_data || {}          # HSDL's existing 12-signal payload
  {
    score:   (doc.health_score || 0).to_f / 100.0,   # normalize to 0..1
    signals: data.transform_values { |v| { value: v, weight: 1.0 } }
  }
end
```

The built-in `:completeness` facet stays registered alongside it. After each
visit (and on backfill), `Enliterator::Facets.recompute!(doc)` writes a `health`
facet row reflecting HSDL's score — without changing `health_data`/`health_score`
themselves.

### 4b. Two embedding kinds, not one

HSDL keeps its existing `embedding` and `full_text_embedding` columns. Enliterator
mirrors them as two named Embedding kinds so the tending loop's neighbor search
works:

- `embedding` → `enliterator_embeddings` row with `kind: "primary"`
- `full_text_embedding` → `enliterator_embeddings` row with `kind: "full_text"`

The Visitor uses the `"primary"` kind for neighbor context. The unique
`[embeddable_type, embeddable_id, kind]` index keeps the two distinct.

---

## 5. Wire the scheduled walk to sidekiq-cron

`rake enliterator:tend` enqueues `TendingVisitJob`s for stale/untended `DocMetum`
records, per stream. Add it to HSDL's sidekiq-cron schedule:

```yaml
# config/schedule.yml  (sidekiq-cron)
enliterator_tend:
  cron: "0 * * * *"            # hourly; the batch cap bounds each run
  class: "EnliteratorTendCron" # thin wrapper that shells the rake task, or invoke Rake directly
  queue: enliterator
```

```ruby
# app/jobs/enliterator_tend_cron.rb  (thin host-side wrapper — additive, HSDL-owned)
class EnliteratorTendCron
  include Sidekiq::Job
  def perform
    Rake::Task["enliterator:tend"].invoke
  ensure
    Rake::Task["enliterator:tend"].reenable
  end
end
```

Each run enqueues up to `tend_batch_size` per model/stream and logs a cap-hit
warning if more stale records remain, so the hourly cadence drains the backlog
without a thundering herd.

---

## 6. Backfill plan

Goal: lift HSDL's existing one-shot artifacts into the compounding store
**without** re-running the LLM on day one and without editing production code.
Run as a `rails runner` task, idempotently, in batches.

**Order matters** — embeddings first (so neighbor context exists), then facets,
then seed claims from existing summaries, then let the scheduled walk take over.

1. **Mirror embeddings (no re-embed).** Copy each `DocMetum`'s `embedding` →
   `Embedding(kind: "primary")` and `full_text_embedding` →
   `Embedding(kind: "full_text")`. Set `content_hash` to the SHA256 of
   `to_enliterator_text` so future visits skip re-embedding unchanged text. Skip
   records already mirrored (the unique index makes this safe to re-run).

   ```bash
   set -a; source ~/.hsdl-rails.env; set +a
   bin/rails runner - <<'RUBY'
   DocMetum.where.not(embedding: nil).find_each(batch_size: 500) do |doc|
     [["primary", doc.embedding], ["full_text", doc.full_text_embedding]].each do |kind, vec|
       next if vec.nil?
       e = doc.enliterator_embeddings.find_or_initialize_by(kind: kind)
       e.embedding  = vec
       e.dimensions = 1536
       e.model      = "text-embedding-3-small"
       e.content_hash ||= Digest::SHA256.hexdigest(doc.to_enliterator_text.to_s)
       e.save!
     end
   end
   RUBY
   ```

2. **Recompute facets.** With embeddings present, run
   `Enliterator::Facets.recompute!(doc)` per record to write `completeness` and
   `health` facet rows from existing `health_data`/`health_score`. No LLM call.

3. **Seed claims from `summary_data` (optional, no LLM).** For each summary field
   worth tracking, create a Claim keyed by field, `attributed_to:
   "hsdl-backfill"`, `status: "draft"`. These become the baseline the first real
   visit reconciles against — so the very first compounding pass already has prior
   understanding to build on.

   ```bash
   bin/rails runner - <<'RUBY'
   DocMetum.where.not(summary_data: nil).find_each(batch_size: 500) do |doc|
     (doc.summary_data || {}).each do |key, value|
       next if doc.enliterator_claims.live.exists?(key: key.to_s)
       doc.enliterator_claims.create!(
         key: key.to_s, value: value, status: "draft",
         attributed_to: "hsdl-backfill", confidence: nil
       )
     end
   end
   RUBY
   ```

4. **(Optional) Seed Visit history from `enrichment_metadata`.** If you want the
   prior enrichment runs visible as immutable history, write one `succeeded`
   `enliterator_visits` row per historical run, carrying the old payload in
   `raw_response`. Cosmetic provenance only — not required for the loop to start.

5. **Hand off to the scheduled walk.** Once embeddings + facets (+ optional seed
   claims) exist, enable the sidekiq-cron entry. `enliterator:tend` picks up
   never-succeeded records and begins real compounding visits — each one reading
   the seeded claims and neighbors, reconciling, and improving from there.

Run the backfill in maintenance windows, batched, and re-runnable (every step is
idempotent via `find_or_initialize_by` / `live.exists?` guards).

---

## What this does NOT do

- It does **not** modify `DocMetum`'s existing columns, `enrichment_metadata`,
  `health_data`/`health_score`, `summary_data`, `embedding`, or
  `full_text_embedding`. Those remain HSDL's source of truth until HSDL chooses
  otherwise.
- It does **not** delete or rewrite HSDL's current enrichment pipeline. The
  engine runs alongside it; cutover is a separate, later decision.
- It does **not** require any change to HSDL production behavior to install — the
  only behavioral change is the new hourly cron, which can be disabled instantly.

This guide is applied under review. Treat each section as a reviewable, revertible
increment.
