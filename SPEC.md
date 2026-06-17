# Enliterator v0.1 — Build Contract

This file is the authoritative spec for the engine. Build exactly to it. When a
detail is unspecified, prefer the simplest idiomatic Rails 8 choice and leave a
`# NOTE:` comment. Do not invent scope beyond "v0.1 scope" below.

Enliterator is a mountable Rails engine that confers literacy on data. A host
model becomes **Tendable**; each scheduled **Visit** reads the record's
accumulated **Claims** + history + corpus neighbors and reconciles understanding
via a language model. Understanding **compounds** across visits — that closed
loop is the whole point. (See the literacy ladder: searchable → structured →
provenanced → tended → **compounding**.)

First consumer: **HSDL** (hsdl-ai), Rails 8.1, **Sidekiq** (so jobs must be
plain ActiveJob — never depend on Solid Queue). LLM substrate: **AWS Bedrock**
(Claude). Embeddings default: **OpenAI text-embedding-3-small (1536d)** to stay
compatible with HSDL's existing `vector(1536)` columns.

Namespace: `Enliterator`. Table prefix: `enliterator_`. All migrations live in
the engine's `db/migrate`. The engine owns its pgvector extension enablement.

---

## v0.1 scope (build all of this)

IN: Tendable concern · Embedding/Visit/Claim/Facet models + migrations · the
tending Visitor loop (the compounding contract) · TendingVisitJob (ActiveJob) +
a stale-walk rake task · LLM adapters (Base/Bedrock/Null) · Embedder adapters
(Base/OpenAI/Null) · Facets registry · Enliterator.configure DSL (already in
`lib/enliterator.rb`) · RSpec suite (green) · README + HSDL adoption guide.

OUT (defer, do NOT build): entity/relationship knowledge graph (HSDL already has
one) · MCP tools · Slack/expert human-in-the-loop · dynamic per-host scheduler
UI · the CE/moma adoption. Leave a `## Deferred` note in README listing these.

---

## File layout (create exactly these)

```
db/migrate/                         (timestamps: use sequential 20260606NNNNNN)
  *_enable_enliterator_pgvector.rb
  *_create_enliterator_embeddings.rb
  *_create_enliterator_visits.rb
  *_create_enliterator_claims.rb
  *_create_enliterator_facets.rb
app/models/enliterator/application_record.rb        (exists; make it abstract base)
app/models/enliterator/embedding.rb
app/models/enliterator/visit.rb
app/models/enliterator/claim.rb
app/models/enliterator/facet.rb
app/models/concerns/enliterator/tendable.rb
app/services/enliterator/tending/visitor.rb
app/services/enliterator/facets.rb                  (registry + default facet)
app/services/enliterator/adapters/llm/base.rb
app/services/enliterator/adapters/llm/null.rb
app/services/enliterator/adapters/llm/bedrock.rb
app/services/enliterator/adapters/embedder/base.rb
app/services/enliterator/adapters/embedder/null.rb
app/services/enliterator/adapters/embedder/openai.rb
app/jobs/enliterator/tending_visit_job.rb
lib/tasks/enliterator_tasks.rake                    (exists; add enliterator:tend)
spec/...                                            (see Tests)
README.md                                           (rewrite)
HSDL_ADOPTION.md
```

Zeitwerk maps `app/services/enliterator/adapters/llm/bedrock.rb` →
`Enliterator::Adapters::LLM::Bedrock`. Keep that mapping exact.

---

## Schema (polymorphic ids are STRING to support UUID hosts like HSDL's DocMetum)

All polymorphic `*_id` columns are `:string` (HSDL `doc_meta.id` is a uuid;
other hosts use bigint — string holds both). Index `[*_type, *_id]`.

### enliterator_embeddings
- `embeddable_type:string`, `embeddable_id:string` (polymorphic, string id)
- `kind:string` not null default `"primary"` — supports multiple named vectors per record (e.g. "primary", "full_text")
- `embedding:vector` limit = `Enliterator.configuration.default_embedding_dimensions` (default 1536) — in the migration hardcode 1536 with a `# NOTE:` that it's the configured default
- `dimensions:integer`
- `model:string` — embedder model id that produced it
- `content_hash:string` — SHA256 of embedded text; skip re-embed when unchanged
- timestamps
- indexes: unique `[embeddable_type, embeddable_id, kind]`; HNSW cosine index on `embedding` (`using: :hnsw, opclass: :vector_cosine_ops`)
- model: `has_neighbors :embedding`

### enliterator_visits  (PROV Activity — the compounding spine; immutable history)
- `tendable_type:string`, `tendable_id:string`
- `stream:string` not null
- `status:string` not null default `"pending"`  (pending/running/succeeded/failed)
- `model:string` — LLM model id used
- `prompt_version:string`
- `input_refs:jsonb` default `{}` — what this visit read: `{prior_visit_ids:[], neighbor_ids:[], claim_keys:[]}`
- `raw_response:jsonb` default `{}`
- `reconciliation:jsonb` default `{}` — `{added:[], updated:[], deleted:[], noop:[]}` (claim keys)
- `confidence:float`
- `tokens:jsonb` default `{}`
- `duration_ms:integer`
- `error:text`
- `started_at:datetime`, `finished_at:datetime`
- timestamps
- indexes: `[tendable_type, tendable_id, stream]`, `[tendable_type, tendable_id, created_at]`

### enliterator_claims  (PROV Entity — a provenanced, reconcilable unit of understanding)
- `tendable_type:string`, `tendable_id:string`
- `key:string` not null — e.g. "summary", "authored_by"
- `value:jsonb` — string/array/object payload
- `confidence:float`
- `status:string` not null default `"draft"`  (draft/verified/superseded)
- `locked:boolean` not null default false — curator anchor; locked claims are never auto-superseded
- `review_state:string` not null default `"pending"` (pending/approved/rejected)
- `visit_id:bigint` (FK enliterator_visits, nullable) — prov:wasGeneratedBy
- `derived_from:jsonb` default `[]` — prov:wasDerivedFrom: `[{type:"claim"|"source", id:...}]`
- `attributed_to:string` — prov:wasAttributedTo: agent (model id / expert)
- `superseded_by_id:bigint` (self FK, nullable)
- timestamps
- indexes: `[tendable_type, tendable_id, key]`, `[superseded_by_id]`
- scope `current -> where(superseded_by_id: nil)`; scope `live -> current.where.not(status: "superseded")`

### enliterator_facets  (weighted-signal quality scorer — HSDL RecordQuality pattern)
- `tendable_type:string`, `tendable_id:string`
- `name:string` not null
- `score:float`
- `signals:jsonb` default `{}` — `{signal_key => {value:, weight:}}`
- `computed_at:datetime`
- timestamps
- indexes: unique `[tendable_type, tendable_id, name]`

---

## Models

`Enliterator::ApplicationRecord` — `self.abstract_class = true`.

`Embedding` — `belongs_to :embeddable, polymorphic: true`; `has_neighbors :embedding`.
Class helper `Embedding.nearest_to(vector, kind: "primary", limit: 5)` returning
embeddings ordered by cosine distance (use neighbor's `nearest_neighbors`).

`Visit` — `belongs_to :tendable, polymorphic: true`; `has_many :claims` (FK visit_id).
`#to_state` → compact hash `{stream:, confidence:, summary: reconciliation, at: created_at}` for prompt context.

`Claim` — `belongs_to :tendable, polymorphic: true`; `belongs_to :visit, optional: true`;
`belongs_to :superseded_by, class_name: "Enliterator::Claim", optional: true`.
`#to_state` → `{key:, value:, confidence:, status:, locked:}`.
`#supersede!(by_claim)` sets status "superseded" + superseded_by.

`Facet` — `belongs_to :tendable, polymorphic: true`.

---

## Tendable concern  (app/models/concerns/enliterator/tendable.rb)

```ruby
module Enliterator
  module Tendable
    extend ActiveSupport::Concern
    included do
      has_many :enliterator_visits,     class_name: "Enliterator::Visit",     as: :tendable,   dependent: :destroy
      has_many :enliterator_claims,     class_name: "Enliterator::Claim",     as: :tendable,   dependent: :destroy
      has_many :enliterator_facets,     class_name: "Enliterator::Facet",     as: :tendable,   dependent: :destroy
      has_many :enliterator_embeddings, class_name: "Enliterator::Embedding", as: :embeddable, dependent: :destroy
      Enliterator.register_tendable(self)
    end

    # Host SHOULD override to provide the text representation used for embedding + tending.
    # Default tries common fields.
    def enliterator_text
      return to_enliterator_text if respond_to?(:to_enliterator_text)
      [try(:title), try(:name), try(:description)].compact.join("\n")
    end

    # The compounding context handed to each visit.
    def literacy_state(stream: nil)
      {
        claims:        enliterator_claims.live.map(&:to_state),
        recent_visits: enliterator_visits.where(stream: stream).order(created_at: :desc).limit(5).map(&:to_state),
        facets:        enliterator_facets.each_with_object({}) { |f, h| h[f.name] = f.score }
      }
    end

    def tend!(stream:, **opts)
      Enliterator::Tending::Visitor.new(self, stream: stream, **opts).call
    end

    def last_tended_at(stream: nil)
      scope = enliterator_visits.where(status: "succeeded")
      scope = scope.where(stream: stream) if stream
      scope.maximum(:finished_at)
    end

    class_methods do
      def enliterator_tendable? = true
    end
  end
end
```

---

## The tending loop  (app/services/enliterator/tending/visitor.rb) — THE compounding contract

`Enliterator::Tending::Visitor.new(tendable, stream:, llm: Enliterator.llm, embedder: Enliterator.embedder)`

`PROMPT_VERSION = "v0.1"` constant on the class.

`#call`:
1. Create a `Visit` (status "running", started_at now, model: `llm.model_id`, prompt_version, stream).
2. `state = tendable.literacy_state(stream:)` — prior claims + recent visits + facets. **This is what makes it compound — prior visits condition the next.**
3. `neighbors = nearest_neighbors(tendable, limit: 5)` — corpus context via embeddings (skip gracefully if the record has no embedding yet; record `input_refs[:neighbor_ids]`).
4. `response = llm.tend(text: tendable.enliterator_text, stream: stream, state: state, neighbors: neighbors)` — returns a parsed structured object (see LLM Base).
5. `recon = reconcile!(response.parsed["claims"], visit)` — apply the reconcile contract.
6. Update visit: status "succeeded", raw_response, reconciliation: recon, confidence: response.parsed["confidence"], finished_at, duration_ms, input_refs, tokens.
7. `Enliterator::Facets.recompute!(tendable)`.
8. Return the visit.
9. On any error: set visit status "failed", error: message, finished_at; re-raise.

### reconcile! (the mem0-style ADD/UPDATE/DELETE/NOOP contract)
Input: array of `{ "key", "value", "confidence", "op" }` where op ∈ ADD|UPDATE|DELETE|NOOP (default ADD if key absent, UPDATE if a live claim with that key exists).
For each proposed claim, find the current live claim for `key` on this tendable:
- **ADD** (no existing live claim): create a Claim (status "draft", visit:, attributed_to: llm.model_id, confidence:).
- **UPDATE** (existing, not locked): create a new Claim; call `old.supersede!(new)`; set `new.derived_from = [{type:"claim", id: old.id}]`. (Provenance chain preserved.)
- **UPDATE** on a **locked** claim: NOOP it (record under reconciliation[:noop]); never overwrite a curator anchor.
- **DELETE** (existing, not locked): mark existing claim status "superseded" (no replacement).
- **NOOP**: record, change nothing.
Return `{added:[keys], updated:[keys], deleted:[keys], noop:[keys]}`.

`nearest_neighbors(tendable, limit:)`: take the tendable's "primary" embedding; if
present, `Enliterator::Embedding.nearest_to(vec, kind: "primary", limit:)` excluding
self; map to the embeddable records (or just return embedding rows). If no embedding, `[]`.

---

## Adapters

All adapters are POROs under `Enliterator::Adapters`. Provider gems are
**lazy-required** inside the adapter; if missing, raise
`Enliterator::ConfigurationError` with an actionable message
("add `gem \"aws-sdk-bedrockruntime\"` to your host Gemfile").

### LLM::Base — interface
- `#model_id` → string
- `#tend(text:, stream:, state:, neighbors:)` → returns an object responding to
  `.parsed` (Hash with `"claims" => [...]` and `"confidence" => Float`), `.raw` (Hash),
  `.tokens` (Hash). Implement a small `Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)`.
- Base builds the prompt: a SYSTEM instruction telling the model it is tending a
  single record, must read prior claims/visits/neighbors, and must return
  structured claims with an op (ADD/UPDATE/DELETE/NOOP) + confidence; and a USER
  payload (the text + JSON of state + neighbor summaries). Put prompt-building in
  Base (`#build_system`, `#build_user(text:, stream:, state:, neighbors:)`) so
  Bedrock/others share it. Define the JSON schema for the structured output in Base
  (`RESPONSE_SCHEMA`).

### LLM::Null
- `model_id` = "null". `#tend(...)` returns a Result with `parsed: {"claims"=>[], "confidence"=>0.0}` (inert; safe for tests). Do NOT call any network.

### LLM::Bedrock
- `initialize(model_id:, region: ENV["AWS_REGION"] || "us-east-1", client: nil)`.
- Lazy `require "aws-sdk-bedrockruntime"`. Use `Aws::BedrockRuntime::Client` `#converse`
  with: `system:` (build_system), `messages:` (one user message = build_user),
  and a `tool_config` with ONE tool ("emit_claims") whose `input_schema` is
  `RESPONSE_SCHEMA`, plus `tool_choice: {tool: {name: "emit_claims"}}` to force
  structured output. Parse the tool-use block → `parsed`. Map usage → tokens.
- Accept an injected `client:` so specs can stub with `Aws::BedrockRuntime::Client`
  stubbed responses (`Aws.config[:bedrockruntime] = {stub_responses: true}` pattern)
  — but keep it simple; the Bedrock adapter spec may use a hand-rolled fake client
  responding to `#converse`. Live Bedrock is validated by the host once AWS creds exist.
- `# NOTE:` model ids change; do not hardcode — read from `model_id`. Document a
  current default in README (e.g. an Anthropic Claude on Bedrock model id).

### Embedder::Base — interface
- `#model_id` → string
- `#embed(text)` → Array<Float> of `dimensions`
- `#dimensions` → integer

### Embedder::Null
- `model_id` = "null". `#embed(text)` returns a DETERMINISTIC pseudo-vector of
  length `Enliterator.configuration.default_embedding_dimensions` derived from a
  hash of the text (so neighbor math works in tests without a network). `#dimensions` accordingly.

### Embedder::OpenAI
- `initialize(model: "text-embedding-3-small", api_key: nil, client: nil)`.
- Lazy `require "openai"` (the official `openai` gem, as used by HSDL). Call the
  embeddings endpoint; return the vector. Accept injected `client:` for specs.
- `#dimensions` = 1536 for text-embedding-3-small.

---

## Facets registry  (app/services/enliterator/facets.rb)

```ruby
module Enliterator
  module Facets
    def self.register(name, &block) ...      # block.call(tendable) => {score: Float, signals: Hash}
    def self.registry ...                     # {name => block}
    def self.recompute!(tendable)             # run all registered facets, upsert Facet rows (computed_at: now)
    def self.load_default!                    # idempotently register :completeness
  end
end
```
Default `:completeness` facet: score = fraction of a small expected set present —
e.g. `[has any live claim?, has primary embedding?, has >=1 succeeded visit?]` →
score in [0,1], signals documenting each. Host apps register richer facets
(HSDL maps its 12-signal health here).

---

## Job + scheduler

`Enliterator::TendingVisitJob < Enliterator::ApplicationJob` (ApplicationJob sets
`queue_as { Enliterator.configuration.queue_name }`). `#perform(tendable, stream)`
accepts a GlobalID-resolvable record (ActiveJob serializes it) → `tendable.tend!(stream:)`.
`retry_on StandardError, wait: :polynomially_longer, attempts: 3` and
`discard_on ActiveJob::DeserializationError`.

`lib/tasks/enliterator_tasks.rake` — add task `enliterator:tend` that, for each
registered tendable model and each configured stream, selects up to
`tend_batch_size` records whose newest succeeded visit is older than `stale_after`
(or null), and enqueues `TendingVisitJob`. Hosts wire this to their scheduler
(HSDL: sidekiq-cron; others: solid_queue recurring). Log how many were enqueued
and note any cap hit (no silent truncation).

---

## Tests (RSpec; suite MUST be green) — spec/dummy is the host app

Set up: add `rspec-rails`, generate `spec/rails_helper.rb`. The dummy app
(`spec/dummy`) gets pgvector enabled and a `widgets` table + `Widget` model that
`include Enliterator::Tendable` and defines `to_enliterator_text`. Run engine
migrations into the dummy. Configure `Enliterator` in `rails_helper` to use Null
adapters by default.

Required specs (use the Null/Stub adapters — NO network):
- `claim_spec.rb`: supersede! chains; `live`/`current` scopes.
- `tending/visitor_spec.rb`: a visit with a STUB llm that returns one ADD then
  (second call) an UPDATE for the same key → asserts: a new Visit row each call,
  first call creates a draft claim, second call supersedes it and links
  derived_from, reconciliation hashes correct, **and the second llm call received
  the first claim in its `state`** (prove compounding — assert the stub captured a
  non-empty `state[:claims]` on the 2nd call). Also: locked claim is NOT
  superseded (NOOP). This spec is the heart — it proves rung 5.
- `facets_spec.rb`: completeness rises from 0 toward 1 as claims/embeddings/visits appear.
- `embedding_spec.rb`: with Null embedder, `nearest_to` returns rows ordered by distance.
- `tendable_spec.rb`: associations + `literacy_state` shape + registration.
- `adapters/llm/null_spec.rb`, `adapters/embedder/null_spec.rb`: contract conformance.
- `adapters/llm/bedrock_spec.rb`: with an injected fake `#converse` client returning
  a tool-use block, `#tend` parses claims + tokens correctly (no real AWS).

Green bar: `bundle exec rspec` passes, zero failures. Use `DatabaseCleaner` or
transactional fixtures. Keep specs fast and deterministic.

---

## Done = all of:
- `bundle install` clean; `bundle exec rspec` green.
- Every file above exists and is consistent with this contract.
- README rewritten (what/why, the ladder, quick start, configure DSL, the loop,
  `## Deferred` list) + HSDL_ADOPTION.md (mount; `include Tendable` on DocMetum;
  map `enrichment_metadata`→Visit, `health_data`/`health_score`→a Facet,
  `summary_data`→Claims; keep existing `embedding`/`full_text_embedding` by
  registering two Embedding kinds or backfilling; Bedrock + OpenAI config; wire
  `enliterator:tend` to sidekiq-cron; backfill plan; nothing in HSDL's prod code
  is edited by us — this is a guide).

---

# v0.2 — Staffing & Routing (escalation is FOUNDATIONAL; build it in the first routing pass)

Supersedes v0.1's "routing deferred" stance. **Routing is not a config knob; it is a
first-class StaffingPolicy.** Enliteration is the allocation of cognitive capacity to
records — deciding how much mind to bring to a record in a given state IS the curatorial
act (see Basic Memory: "Enliteration as Staffing — Capability Allocation Is the Curatorial
Act"). A tending **stream is a ROLE**; a LiteLLM **alias is a capability TIER**; the policy
is the **org chart**.

**Why escalation is foundational, not deferred:** the per-Visit `tier` and the escalation
chain are the substrate every later capability reads — re-staffing ("re-tend everything last
touched by `cheap`"), cost attribution, and trust (which tier asserted a claim). If that data
is not recorded from the first routing commit, it can never be reconstructed. Build it now.

Routing target: the **LiteLLM gateway** (`https://llm.domt.app/v1`, OpenAI-compatible,
v1.82.3). Tiers are aliases; LiteLLM owns provider/fallback/load-balancing/cost. The engine
names intent (alias) + tags the call; it NEVER names a provider. Validate the policy against
`GET /v1/models` at boot. (Live alias facts: `cheap`/`fast`/`balanced`→gemma4 [tool_choice
only, 8192 ctx, free, on-prem], `quality`→gpt-5.4 [tools+json_schema], `embed`→
text-embedding-3-small 1536d, `instant`→apfel [4096 ctx], `claude-*` DOWN. Portable
structured-output path across tiers = forced `tool_choice` — already what the engine uses.)

## Config (extends Enliterator.configure)
- `gateway_base_url` (default `"https://llm.domt.app/v1"`)
- `gateway_api_key` (LiteLLM project key; from ENV — never committed)
- `staffing` → an `Enliterator::Staffing::Policy`

## Enliterator::Staffing::Policy  (app/services/enliterator/staffing/policy.rb)
Declarative org chart.
- `assign(stream, tier:)` — role→tier map; `embedding_tier` for the embed alias.
- `ladder` — ordered tiers for escalation, e.g. `["cheap", "quality"]`.
- `escalate_when` — callable `(visit) -> Bool`; default `->(v){ v.confidence.to_f < escalation_threshold }`
  (default threshold 0.6). ALSO escalate when the model's parsed output sets an optional
  `escalate`/`needs_review` flag (add optional boolean `escalate` to RESPONSE_SCHEMA).
- `max_promotions` (default 1) — bound the climb.
- `verify_floor` — minimum tier permitted to mint `verified` claims (default: top configured
  tier). Below the floor, claims stay `draft` regardless of model assertion. (Prevents a
  cheap pass from poisoning the compounding well.)
- Constraints: `on_prem_tiers` (e.g. `["cheap"]`); a tendable/stream may declare
  `on_prem_only` (host hook, e.g. `enliterator_on_prem_only?`) → ladder restricted to
  on-prem tiers, never routed off-prem even on escalation; `context_cap_for(tier)` →
  never route inputs over a tier's window (apfel 4096), escalate to a larger-context tier
  or (future) chunk.
- API: `tier_for(stream)`, `ladder_from(tier)`, `escalate?(visit)`, `may_verify?(tier)`,
  `allowed_tiers(tendable, stream)` (applies constraints), `validate!(available_aliases)`
  (raises on unknown alias — fail fast at boot).
- Provide a safe DEFAULT policy when the host configures none (all streams → first available
  alias; ladder = [that]; verify_floor = that) so the engine still runs.

## Schema additions (new migration; additive to v0.1)
- `enliterator_visits`: add `tier:string` (alias used), `escalated_from_id:bigint`
  (self FK nullable — senior→junior link), `escalation_step:integer default 0`,
  `applied:boolean default true` (false for a junior visit whose reconciliation was NOT
  applied because it escalated). Index `[tendable_type, tendable_id, tier]`.
- `enliterator_claims`: add `tier:string` (tier that minted/last-updated the live claim);
  keep `attributed_to` as `"<tier>:<model_id>"`.

## Adapters
- `Enliterator::Adapters::LLM::Gateway` (`adapters/llm/gateway.rb`): OpenAI-compatible
  (`require "openai"`; `OpenAI::Client.new(api_key:, base_url:)`);
  `initialize(tier:, base_url:, api_key:, client: nil)`; `model_id` = the tier alias;
  `#tend` = chat completions with FORCED `tool_choice` on `emit_claims` (portable across
  gpt-5.x + gemma4; do NOT rely on json_schema). Passes `metadata: {tags: [...]}` (see Spend).
  Reuses Base#build_system/#build_user/RESPONSE_SCHEMA. Raises ConfigurationError if the
  `openai` gem is missing.
- `Adapters::Embedder::OpenAI`: add `base_url:` passthrough so it can point at the gateway
  `embed` alias (default nil → api.openai.com; host sets gateway).
- Tier→adapter resolution: `Enliterator.llm(tier:)` builds/memoizes a Gateway adapter per
  tier from gateway config. The Visitor requests the tier the policy returns. BACK-COMPAT:
  if `staffing` is unset, fall back to the v0.1 single `llm_adapter`/Null path (keeps existing
  specs green).

## Visitor changes — the loop WITH escalation
1. `tier = staffing.tier_for(stream)`; `allowed = staffing.allowed_tiers(tendable, stream)`;
   clamp tier + ladder to `allowed` (on-prem / context constraints).
2. Run a visit at `tier` → proposed claims + confidence. Record the Visit (`tier`, tokens,
   raw). Do NOT reconcile yet.
3. Escalation loop: while `staffing.escalate?(current_visit)` AND a higher tier exists in the
   allowed ladder AND `escalation_step < max_promotions`: run a higher-tier visit, passing the
   junior's proposed claims into `state` as `proposed_by_lower_tier` (senior REVIEWS junior —
   compounding within one tending). Set `escalated_from_id`, `escalation_step += 1`, and mark
   the superseded junior `applied: false`.
4. **Only the final tier's visit reconciles/writes claims** (single `reconcile!` on the final
   parsed claims). Junior visits are provenance only (`applied:false`) — no double writes.
5. Verification gate: a created/updated claim may be `verified` ONLY if
   `staffing.may_verify?(final_tier)` AND the model asserted it; else `draft`. Set
   `claim.tier = final_tier`, `attributed_to = "<final_tier>:<model_id>"`.
6. `Facets.recompute!` as before.

## Spend attribution (per loop)
Every gateway request carries `metadata: {tags: [...]}`:
`["enliterator", "host:<host>", "stream:<stream>", "tier:<tier>", "esc:<step>",
"record:<Class>/<id>"]`. LiteLLM logs to `LiteLLM_SpendLogs.request_tags` / `DailyTagSpend`
(NOTE: project keys cannot read those back — master-key/admin only). The engine's OWN
per-loop ledger is `Visit.tokens` grouped by `stream`/`tier`; add
`Enliterator::Spend.by_stream(host:, since:)` over Visit rows (tokens; optional local price
map → $). Tags are the join key to LiteLLM's authoritative dollars.

## Done = all of (this phase):
- `Staffing::Policy` (assign/ladder/escalate_when/max_promotions/verify_floor/constraints +
  `validate!` against `/v1/models`); safe default policy.
- `LLM::Gateway` adapter (forced tool_choice) + embedder `base_url`; `Enliterator.llm(tier:)`.
- Visitor escalates `cheap`→`quality` on low confidence (bounded); senior conditions on the
  junior's proposed claims; only the final tier writes; junior recorded `applied:false`.
- `verify_floor` enforced (`cheap` cannot mint `verified`).
- Migration adds `visits.tier/escalated_from_id/escalation_step/applied` + `claims.tier`.
- Spend tags emitted; `Spend.by_stream` helper.
- Specs green, ADDING:
  - `staffing/escalation_spec.rb`: low-confidence junior → exactly one senior visit; senior's
    `state` contains the junior's proposed claims; only the senior is `applied:true` and writes;
    `escalated_from_id` set; `max_promotions` respected.
  - `staffing/verify_floor_spec.rb`: with `verify_floor "quality"`, a `cheap` visit leaves
    claims `draft` even on high asserted confidence; a `quality` visit may verify.
  - `staffing/constraint_spec.rb`: an `on_prem_only` tendable never escalates off-prem (ladder
    clamped).
  - `staffing/policy_spec.rb`: `validate!` raises on unknown alias; `tier_for`/`ladder_from`.
  - `adapters/llm/gateway_spec.rb`: injected fake OpenAI client → `#tend` parses `tool_calls`
    into claims; `metadata.tags` present on the request. (No network.)
- README `## Deferred`: move routing/staffing → implemented; remaining deferred = entity graph,
  MCP tools, human-in-the-loop UI, Bedrock tier, dynamic per-host scheduler UI, input chunking
  for small-context tiers.

---

# v0.3 — Stream Contracts + Governed Suggestion Loop + Locked-Claim Import

Discovered at the first HSDL thesis batch: a stream with no output contract lets the model
freelance claim keys (`author` vs `authored_by`, redundant `institution`/`date`). Key drift
breaks reconciliation (re-tend ADDs duplicates instead of UPDATE) — it corrupts compounding
at scale. The fix is BOTH a controlled vocabulary AND a sanctioned channel to propose
additions. The ontology itself becomes a tended, governed thing. See Basic Memory:
"The Vocabulary Compounds — Controlled Claim Keys + a Governed Suggestion Loop."

**Hard back-compat rule:** v0.1+v0.2 ship GREEN at 114 examples. Keep them green. Every new
behavior is gated on a contract being PRESENT; when absent, behavior is identical to v0.2
(open keys, no suggestions, injected-llm path untouched).

## 1. Stream output contract (Staffing::Policy)
- New DSL: `stream(name, tier:, keys:)` where `keys` is `{ key_sym => "description", ... }`.
  Sets BOTH the tier assignment (like `assign`) AND the allowed-key contract. `assign(name, tier:)`
  stays (no contract → unconstrained, back-compat).
- API: `keys_for(stream)` → `{key => desc}` or `nil`; `allowed_keys(stream)` → `[String]` or `nil`
  (nil = unconstrained). `validate!` unchanged.

## 2. Prompt + schema (Adapters::LLM::Base)
- `#tend` gains keyword `contract: nil` (a `{key => description}` hash). Thread it through
  `build_system`/`build_user` and schema. ALL adapters' `#tend` accept `contract:` (Null/Bedrock
  may ignore; Gateway honors).
- When `contract` present:
  - `build_system` lists the allowed keys + descriptions and instructs: "Use ONLY these keys.
    If you observe something worth asserting that no allowed key covers, DO NOT invent a key —
    add it to `suggestions` instead."
  - Build a per-call schema where claim `key` is `{enum: allowed_keys}`.
  - Always include optional top-level `suggestions: [{proposed_key, rationale, example_value}]`
    in the schema (not required).
- When `contract` absent: byte-identical to v0.2 (open `key` string, no suggestions emphasis).
  RESPONSE_SCHEMA stays the default; build a contract-variant only when contract is passed.

## 3. Enliterator::Suggestion (engine-local, pluggable sink)
- Migration `enliterator_suggestions`: `tendable_type:string`, `tendable_id:string`,
  `stream:string`, `proposed_key:string`, `rationale:text`, `example_value:jsonb default {}`,
  `tier:string`, `model:string`, `visit_id:bigint`, `status:string default "pending"`
  (pending/approved/mapped/rejected), `review_note:text`, timestamps. Index
  `[proposed_key, status]`, `[stream, status]`, `[tendable_type, tendable_id]`.
- Model: `belongs_to :tendable, polymorphic: true`; `belongs_to :visit, optional: true`;
  scopes `pending`; class `gaps(stream: nil)` → group by proposed_key (count distinct tendables,
  sample rationale/example), ranked desc; instance `approve!(note:)/map!(note:)/reject!(note:)`.
- `config.suggestion_sink` (callable, default nil): if set, called with each new Suggestion on
  create (stub for forwarding to a shared tracker / KN later).

## 4. Visitor changes
- POLICY path: `contract = Enliterator.staffing.keys_for(stream)`; pass `contract:` to `tend`.
- After parse: if contract present, reconcile ONLY claims whose key ∈ allowed_keys (drop/ignore
  off-list — schema enum should already prevent them; this is the safety net). When absent,
  reconcile all (v0.2).
- Persist `response.parsed["suggestions"]` (Array) as `Enliterator::Suggestion` rows
  (tendable, stream, proposed_key, rationale, example_value, tier=final tier, model, visit).
  Fire `config.suggestion_sink` per row if set.
- Injected-`llm:` path (v0.1 back-compat): no contract, no suggestions — unchanged.

## 5. Locked-claim import (Tendable)
- `Tendable#assert_claim!(key:, value:, locked: true, status: "verified", attributed_to: "host", tier: nil)`:
  upsert the current live claim for `key` on this record with these attributes; idempotent
  (find live claim by key → update; else create). Used by hosts to seed structured metadata as
  first-class claims the LLM never derives. reconcile already NOOPs locked claims on UPDATE, so
  tending will not overwrite them.

## Done = all of (this phase):
- `Staffing::Policy#stream`/`keys_for`/`allowed_keys`; back-compat `assign`.
- Base/Gateway/Null/Bedrock `#tend(contract:)`; contract-variant schema (key enum + suggestions);
  contract-absent path byte-identical to v0.2.
- `Enliterator::Suggestion` model + migration + `gaps` + status setters + `config.suggestion_sink`.
- Visitor: contract-aware reconcile + suggestion persistence (policy path only).
- `Tendable#assert_claim!` (locked/verified upsert, idempotent).
- Migration adds `enliterator_suggestions` (additive).
- Specs green, ADDING (keep the 114 green):
  - `staffing/contract_spec.rb`: `stream` DSL sets tier+keys; `allowed_keys`/`keys_for`.
  - `tending/contract_spec.rb` (policy path, stub per-tier llm honoring `contract:`): a claim with an
    allowed key is written; an off-list key is NOT written; a returned `suggestions` entry becomes an
    `Enliterator::Suggestion` row with provenance; `suggestion_sink` fires.
  - `suggestion_spec.rb`: `gaps` aggregation + `approve!/map!/reject!`.
  - `tendable_assert_claim_spec.rb`: seeds a locked verified claim; a subsequent tend UPDATE NOOPs it;
    `assert_claim!` is idempotent.
  - `adapters/llm/gateway_spec.rb`: extend — when `contract:` passed, the request's tool schema enums
    `key` to the allowed set and includes `suggestions` (fake client; no network).
- README: add "Stream Contracts & Suggestions" section; note `assert_claim!` for host metadata.

---

# v0.5 — Silent-Failure Hardening + Required Keys + Active Observability

Discovered tending the first HSDL thesis batch: with no `ENLITERATOR_LLM_KEY`, `Enliterator.llm(tier:)`
falls back to the inert Null adapter, whose `#tend` returns empty claims at confidence 0.0 and writes
`status: succeeded, applied: true` Visit rows. A 38-record run "succeeded" in 2.7s having called no
model — and the Visitor emitted ZERO log lines, so nothing surfaced it. The truth was in the Visit
table (`model: "null"`) but completely unsignalled. Separately, a required author came back EMPTY at
confidence 1.0 and passed as success (the model never escalated). v0.5 makes the Null fallback LOUD,
lets a stream declare a key REQUIRED (so a confidently-empty fact forces escalation), and makes tending
OBSERVABLE (per-tend logs + a status rollup that exposes a `null` adapter at a glance).

**Hard back-compat rule:** v0.1–v0.4 ship GREEN (156). The contract-absent and required-absent paths
stay byte-identical. New behavior is gated on `allow_null_llm` (a flag) and `required:` (a contract field)
being present.

## 1. Null-adapter refusal (Configuration + Visitor)
- `Configuration#allow_null_llm` (default `false`). Do NOT modify `Enliterator.llm` (no-tier Null path stays identical).
- Visitor `run_tier_visit`: after resolving the tier adapter and BEFORE `enliterator_visits.create!`, raise
  `ConfigurationError` when `adapter.is_a?(Adapters::LLM::Null) && !configuration.allow_null_llm`. Raising
  before the create means a misconfigured real run leaves ZERO phantom Visit rows.
- `spec/rails_helper.rb`: opt the suite in (`allow_null_llm = true`) after each `reset_configuration!`.

## 2. Required keys (Staffing::Policy + Base + Visitor)
- `Policy#stream(name, tier:, keys:, required: nil)` stores `@required_key_map`; `required_keys(stream)` → `[String]` or nil.
  Keys hash stays pristine (contract spec asserts it exactly). `assign` unchanged.
- `Base#system_for(contract, required:)` appends a REQUIRED-keys emphasis block (instruction-level; a JSON
  schema can't force array contents). `tend(... required:)` threaded through Base/Null/Gateway.
- Visitor: read `required = policy.required_keys(stream)`; thread to the adapter only when it accepts `:required`
  AND required is non-nil (mirrors the `contract:`/`tags:` arity guard). In the climb loop, `required_unmet =
  required.present? && required_keys_unmet?(required, parsed["claims"])` (claim absent OR value blank);
  one changed line: `break unless policy.escalate?(current_visit) || required_unmet`. At finalize,
  `may_verify &&= !required_unmet`; write `reconciliation["required_unmet"] = true` ONLY when true.

## 3. Structured logging (Visitor)
- `log_event(event, **fields)` → `Enliterator.logger&.info("[enliterator] event=… k=v …")`; nil-safe, never raises.
- Events: `resolve` (tier, adapter class, model_id — the line that would have named Null), `visit` (per outcome),
  `reconcile` (op-counts + required_unmet), `fail` (error). Both staffing and back-compat paths.

## 4. Enliterator::Report + enliterator:status rake (the smoke alarm)
- `Report.summary(host:, since:, stream:)` — pure Visit read. Per stream: status counts, **adapter/model mix**
  (null surfaces), tier mix, escalation rate, empty-final rate (succeeded+applied that wrote nothing),
  required_unmet count, confidence buckets, merged `Spend.by_stream`.
- `enliterator:status` rake (matches `enliterator:tend` style; `SINCE`/`STREAM` env) prints it and appends
  `<-- WARNING: null adapter ran N visit(s)` when the model mix contains `null`.

## Done = all of (this phase):
- `Configuration#allow_null_llm` default false; Visitor refuses a Null tier on the staffing path before any Visit row; rails_helper opts the suite in.
- `Policy#stream(..., required:)` + `required_keys`; back-compat `assign`/keys-only unchanged.
- `Base#system_for` required emphasis; Base/Null/Gateway `#tend(required:)`; Visitor escalates on unmet required key (bounded by `max_promotions`), bars verified + flags `required_unmet` at the top.
- Structured `[enliterator]` logging at resolve/visit/reconcile/fail on both paths; nil-safe.
- `Enliterator::Report.summary` + `enliterator:status` rake (adapter/model mix surfaces null; empty-final + escalation rates; confidence buckets; required_unmet; Spend rollup).
- Specs green at 181 (was 156), ADDING:
  - `tending/null_guard_spec.rb`: staffing-path Null raises (zero Visit rows) when flag false; permitted when true; no-tier path unaffected.
  - `staffing/required_keys_spec.rb`: storage/reader; nil for `assign`/keys-only.
  - `tending/required_keys_spec.rb`: escalates on absent + blank (`""`/`[]`); no escalation when satisfied; top-tier-unmet → succeeded, no verified, `reconciliation["required_unmet"]==true`; respects `max_promotions`; byte-identical when required unset.
  - `tending/logging_spec.rb`: `resolve` names the Null class + `model_id=null`; `visit` on success; `fail` on raise (raise propagates).
  - `report_spec.rb`: status/totals, adapter mix surfaces null, escalation + empty-final rates, confidence buckets (incl. nil), required_unmet, Spend merge, stream filter.

---

# v0.6 — Mountable UI (Status Browser + Conversation)

The engine grows its first web surface: mount `Enliterator::Engine` and a host gets two
read-paths over its enliteration. (1) A STATUS BROWSER — the `Report` smoke alarm in the
browser, the claim-key vocabulary with live counts + samples, the connection graph,
vocabulary-gap suggestions, and per-record drill-down. (2) A CONVERSATION UI — chat with
the collection's top-level potential, HYBRID-grounded: each turn opens from a collection
SELF-PORTRAIT (what the enliteration knows about itself) AND retrieves the specific tended
records relevant to the question, answering in free-form streamed prose. The engine writes
no new tables; both views are read-only over the v0.1–v0.5 substrate.

**Constraints:** self-contained ERB + inline vanilla JS + inline CSS — NO JS build step, NO
turbo/stimulus/importmap, NO new gems. Engine-generic (works for any host's tended records).
All edits to existing files are additive; the 181 prior specs stay green.

## 1. `Enliterator::Synopsis` (new pure-read service) — the self-portrait
`Synopsis.build(host:, since:, sample_cap: 3, value_chars: 80)` → `{ generated_at, streams:[{stream,tier,tended_count,vocabulary:[{key,description,live_claims,samples}]}], connections:[{key,live_claims,samples}], health, gaps, models }`. tended_count from Visits (Claim has NO stream column); vocabulary from `staffing.keys_for`; connections from connection-named streams (else a key heuristic); health = `Report.summary`; gaps = `Suggestion.gaps`. `Synopsis.to_prompt` → bounded one-line-per-item text for LLM grounding.

## 2. `Enliterator::Conversation` (new service) — the hybrid answerer
`reply(question:, history:, stream:, &block)` → embeds the question, retrieves nearest records (`Embedding.nearest_to`) + their live claims (mirrors `nearest_neighbors`/`literacy_state`), assembles `system = self-portrait` + `user = question + retrieved claims`, calls the adapter's free-form chat, yields streamed deltas, returns `{ answer, records:[refs+distance], tier, degraded }`. Tier = `configuration.conversation_tier || staffing.ladder.last || "quality"`. Bounded by `retrieve_k`/`history_cap`/claim cap.

## 3. `converse` on the LLM adapters (additive)
`Base#converse(messages:, tags:, stream:, &block)` interface; `Gateway#converse` streams via the official gem's `chat.completions.stream_raw(...).each` (NOT `create(stream:true)`), tags via `extra_body`; `Null#converse` returns a canned answer (yields it word-by-word when streaming) and NEVER raises (conversation writes no rows — the v0.5 phantom-Visit hazard doesn't apply; `Conversation` surfaces a soft `degraded: "null-llm"` instead). `Configuration#conversation_tier` added.

## 4. Controllers, routes, views (additive)
Routes: `root → status#index`, `status`, `status/:type/:id` (drill-down; id constraint allows uuids), `chat → conversation#index`, `chat/stream → conversation#stream` (POST). `StatusController` (index = Synopsis; show = a record's live claims/visits/facets, with a `tendable_models` allow-list on the polymorphic Type). `ConversationController` includes `ActionController::Live`; `stream` writes `text/event-stream` token/provenance/done events, `ensure response.stream.close`. Views are ERB; the chat client is inline vanilla JS (fetch + `ReadableStream`, NOT EventSource — it can't POST). The layout gains a Status|Chat nav + inline CSS so it renders under any host pipeline.

## Done = all of (this phase):
- `Enliterator::Synopsis` (self-portrait, `build` + `to_prompt`) and `Enliterator::Conversation` (hybrid, streaming) services.
- `converse` on Base/Gateway/Null; `Configuration#conversation_tier`; Null-converse never raises.
- Mountable routes + `StatusController` + `ConversationController` (Live SSE) + ERB views + inline-CSS layout with nav.
- Specs green at 206 (was 181), ADDING: `adapters/llm/converse_spec.rb`, `synopsis_spec.rb`, `conversation_spec.rb`, `requests/enliterator/{status,conversation}_spec.rb`.
- README: "Mounting the UI" note.

---

# v0.7 — Suggestion Review (the ontology tends itself)

The governed-vocabulary loop gets a curatorial surface. When a stream's contract can't express
something, the model files an `Enliterator::Suggestion` (v0.3). v0.7 adds the third mounted view —
a review queue where a curator renders a verdict per proposed_key and the vocabulary tightens.

**Approve is advisory:** it records the verdict and the view surfaces the exact `keys:` diff to paste
into the staffing policy — the contract stays a versioned, code-reviewed, reproducible artifact (no
DB-backed contract drift). **Map records a structured target** (`mapped_to`) so a synonym is real data
for future auto-routing. Verdicts act per proposed_key, scoped to pending (idempotent).

## 1. Migration (additive)
`add_column :enliterator_suggestions, :mapped_to, :string`.

## 2. Suggestion — batch verdicts + diff (app/models/enliterator/suggestion.rb)
`approve_key!(key, note:)`, `map_key!(key, to:, note:)`, `reject_key!(key, note:)` — batch over PENDING
rows for a key, return the count. `contract_additions` → `{stream => [approved keys]}` (the paste diff).
`synonyms` → `[{stream, proposed_key, mapped_to}]`. Instance `map!(to:, note:)` records `mapped_to`.

## 3. Routes + controller + view
`get suggestions` + `post suggestions/verdict`. `SuggestionsController#index` (gaps queue + canonical
keys for the Map dropdown + additions + synonyms) and `#verdict` (dispatch by `decision`, guard
unknown / missing map target, flash + redirect). `suggestions/index.html.erb`: ranked pending queue
with Approve / Map(select existing key) / Reject per row; an "add to your contract" snippet per stream;
a synonyms table. Layout gains a Requests nav link + flash; the status "Vocabulary gaps" panel links here.

## Done = all of (this phase):
- `mapped_to` migration; `Suggestion` batch verdicts + `contract_additions` + `synonyms`; `map!(to:)`.
- `suggestions`/`suggestions/verdict` routes; `SuggestionsController`; `suggestions/index` view; nav + flash + status cross-link.
- Approve advisory (no contract mutation; emits the diff); Map records `mapped_to`; verdicts pending-scoped.
- Specs green at 219 (was 207), ADDING: `requests/enliterator/suggestions_spec.rb` + the batch-verdict block in `models/enliterator/suggestion_spec.rb`.
- README: `/enliterator/suggestions` in the "Mounting the UI" list.

---

# v0.8 — The Considerer (the vocabulary tends itself)

178 proposed keys is more than a person can curate row-by-row, but cross-cutting synthesis over the
whole field is what an LLM is good at. The considerer is the tending loop turned on the VOCABULARY:
it reads every open proposed term together (with accumulated PRESSURE + resurgence), decides each —
map onto an existing key, approve as new, or reject — then AUTO-APPLIES the reversible verdicts
(maps + confident rejects) and HOLDS approves (a contract change) for human ratification.

## 1. `Enliterator::ProposedTerm` (materialized pressure)
Migration adds `enliterator_proposed_terms` (proposed_key unique, pressure, distinct_records, by_stream
jsonb, resurged_count, first/last_seen, recommended_* + considered_at, sample_*). `refresh!` recomputes
per-key aggregates from the Suggestion log (bulk `upsert_all` with `update_only:` so a stored
recommendation survives). **pressure** = total proposals ever; **resurged_count** = pending proposals
created after the key's most recent verdict. Scopes `open`/`by_pressure`/`resurged`. ADDITIVE — verdict
authority + `contract_additions`/`synonyms` stay on `Suggestion`.

## 2. Adapter `#decide` (general forced-tool structured call)
`Base/Gateway/Null #decide(messages:, schema:, tool_name:, tags:)` — forces a caller-named tool bound to
an arbitrary schema, returns the parsed args Hash (generalizes the `tend` plumbing). Null → `{}` (inert).

## 3. `Enliterator::Considerer`
`consider!` → `ProposedTerm.refresh!` → load `open.by_pressure` + canonical keys → `adapter.decide` with
a recommendations schema → APPLY per autonomy (`:auto_safe`): auto-apply `map` (valid `map_to` ∈ canonical
+ confidence ≥ `min_confidence`) via `Suggestion.map_key!` and confident `reject` via `reject_key!`;
HOLD `approve` (+ low-confidence) as a `ProposedTerm` recommendation. Returns a summary. Tier =
`considerer_tier || ladder.last || "quality"`. Config: `considerer_tier`/`considerer_autonomy`/`considerer_min_confidence`.

## 4. UI + rake
`/enliterator/suggestions` now ranks by pressure, shows a ⚠ resurged badge + the considerer's held
recommendation (pre-fills the Map target), and adds a "Consider all requests" button (`POST
suggestions/consider`). Rake `enliterator:consider` (refresh + consider!) — wire after `enliterator:tend`.

## Done = all of (this phase):
- `ProposedTerm` migration + model (`refresh!`, pressure, resurged, scopes, recommendation fields).
- `#decide` on Base/Gateway/Null; `Considerer` (auto-apply safe, hold approves); considerer config.
- `suggestions/consider` route + controller action + pressure/resurged/recommendation UI + Consider button; `enliterator:consider` rake.
- Specs green at 235 (was 219), ADDING: `models/enliterator/proposed_term_spec.rb`, `services/enliterator/considerer_spec.rb`, `services/enliterator/adapters/llm/decide_spec.rb`, + considerer/pressure cases in `requests/enliterator/suggestions_spec.rb`.
- README: considerer note (`enliterator:consider` after `enliterator:tend`).

# v0.9 — Convergence (close the vocabulary loop)

v0.8 collapsed the field but didn't make it *settle*: map/reject didn't change what the model sees, so
the next tend re-proposed the same synonyms and they resurged. v0.9 wires the two pieces that make the
loop reach a fixed point — the genuinely contested terms — instead of re-presenting the whole field
every cycle. **Decisions:** approvals go LIVE (effective contract = code keys + approved keys, *derived
from verdicts* — no new table, auditable; the code-diff stays so you can codify); resolved re-proposals
are SUPPRESSED + tracked (`post_verdict_attempts`). Additive; the no-approvals / no-resolved path is
byte-identical, so the v0.8 specs hold unchanged.

## 1. `Enliterator::Contract` (the effective contract)
`Contract.for(stream)` → the code contract (`staffing.keys_for(stream)`) merged with APPROVED-key
extensions: keys of `Suggestion.where(status:"approved", stream:)`, described from the term's
`ProposedTerm.recommended_rationale` (else a default). **Code keys win** on conflict. Returns the code
contract unchanged (nil-preserving) when nothing's approved or `apply_approved_keys=false` — so
`Contract.for == keys_for` when idle. Every contract consumer now reads `Contract.for`: `Visitor`
(schema/system/filter all see approved keys), `Synopsis`, `Considerer#canonical_keys` (approved keys
become valid map targets), `SuggestionsController#canonical_keys`. Config: `apply_approved_keys` (default true).

## 2. Suppress + track resolved re-proposals (`Visitor#persist_suggestions!`)
Migration adds `enliterator_proposed_terms.post_verdict_attempts` (default 0; excluded from
`ProposedTerm::PRESSURE_COLS` so `refresh!` preserves it). `Suggestion.resolved_keys` = set of
proposed_keys with any non-pending verdict. On a tend, a model suggestion whose key ∈ `resolved_keys`
is NOT re-filed; instead `ProposedTerm.where(proposed_key:).update_all("post_verdict_attempts += 1")`.
Unresolved keys persist as before. (Approved keys are now in the effective contract, so the model
emits them as CLAIMS, not suggestions; a stray approved suggestion is resolved → suppressed.)

## 3. UI surfaces the convergence
Status browser marks approved-but-not-codified vocabulary with a `live` chip (curation, not code).
Suggestions review adds a "Re-proposed after a verdict" panel (`post_verdict_attempts > 0` + the verdict
each got) — the "model overruling the curator" signal, the place to reconsider. The approved diff is
retitled "Approved & live — codify in your policy" (the key is already live; the diff lets you make it
permanent in code, after which the DB derivation is redundant).

## 4. The cycle now converges end-to-end
No new rake: `enliterator:tend` (re-proposes) + `enliterator:consider` (verdicts) already compose, but
v0.9 makes the composition settle — tend → consider (auto-map/reject) → next tend suppresses the
resolved keys + emits approved keys as claims → the open field shrinks toward the contested core.

## Done = all of (this phase):
- `Enliterator::Contract.for` (code + approved extensions, code-keys-win, nil-preserving, gated); all consumers wired to it.
- `post_verdict_attempts` migration + preserved across `refresh!`; `Suggestion.resolved_keys`; `Visitor#persist_suggestions!` suppress+track.
- `live` chip in status; "Re-proposed after a verdict" panel + retitled approved section in suggestions.
- Specs green at 247 (was 235), ADDING: `services/enliterator/contract_spec.rb`, `services/enliterator/tending/suppression_spec.rb`, + `post_verdict_attempts`/convergence cases in `proposed_term_spec.rb` and `requests/enliterator/suggestions_spec.rb`.
- README: the converging cycle (tend → consider → tend shrinks the field).

# v0.10 — The Explainer (the fourth surface)

A read-only About page (`/enliterator/about`) that states what enliteracy is, why the collection is
tended, and — the question that drives the project — how compounding attention changes a collection NOW
(dormant → legible; first attention; a self-portrait) and OVER TIME (understanding deepens; the
vocabulary converges; the investment compounds as models/contracts improve). It is the HSDL demo surface
AND the project's own north star: a LIVING document, hand-revised each version. Per "infrastructure as
argument," it demonstrates its own thesis — a resilient live strip pulls real counts (records tended,
visits, claims, streams, vocabulary resolved/open) from the collection it's mounted on, so the
explanation is never abstract. Additive and self-contained (inline styling, no new tables, no network).

## Done = all of (this phase):
- `AboutController#index` (resilient pure-count snapshot; nil + `Rails.logger.warn` on failure, never 500s) + route + `app/views/enliterator/about/index.html.erb`.
- "About" added to the engine nav (right-aligned).
- Specs green at 250 (was 247), ADDING `requests/enliterator/about_spec.rb` (prose renders with no data; live strip appears once tended; links the other three surfaces).
- Revise this page every version — it is the canonical plain-language description of what the engine does.

# v0.11 — Settings (the configuration surface, the fifth surface)

A read-only `/enliterator/settings` window onto the accumulating configuration of THIS enliteration —
the org chart (streams → tiers, the escalation climb per stream, required keys), the effective vocabulary
per stream (code keys + the approved keys that have accrued through curation, each flagged code/`live`),
routing & capability (gateway, ladder, escalation threshold, verify floor, embedding/conversation tiers,
on-prem, context caps), the considerer's autonomy (tier, `auto_safe`, confidence floor, apply-approved),
and tending behavior (models tended, stale_after, batch, queue, suggestion sink, the Null-LLM guard).
Configuration is code (the host initializer); this surface reflects it and does not edit it — the one
thing that genuinely accumulates at runtime, the approved vocabulary, is governed on Requests. (This is
also the seed surface for the coming context tree: it is, today, the ROOT context's settings.)

Fidelity note (asymmetric observability): "Models tended" reads from the Visit log
(`Visit.distinct.pluck(:tendable_type)`), not the in-memory `tendable_models` registry — the registry
fills only as model classes autoload (lazy in dev), so the visit log is the truer authority for "what
this enliteration actually works on."

## Done = all of (this phase):
- `SettingsController#index` (pure-read introspection of `configuration` + `staffing` + effective `Contract.for`) + route + `app/views/enliterator/settings/index.html.erb`.
- "Settings" added to the engine nav (grouped right with About).
- Specs green at 254 (was 250), ADDING `requests/enliterator/settings_spec.rb` (org chart renders; considerer/guard shown; approved key marked live; links to Requests).
- README: fifth surface in the mounting list.

# v0.12 — Speak the library's language (the rename pass)

The engine was re-deriving library/information science under software names. This pass renames toward
the field's own vocabulary so the work is legible to (and contributory for) librarians. **No behavior
change** — pure rename; 254 specs stay green throughout. NOTE: the historical sections above predate
this and use the OLD names; the mapping below translates them.

## The mapping (old → new)
- `Enliterator::Contract` → **`Enliterator::Vocabulary`** (`Vocabulary.for(facet)` = effective controlled vocabulary: code terms + curator-authorized terms). Authority control.
- A tending **stream** → a **facet** (Ranganathan's faceted classification — the dimension a record is read along). Column renames: `visits.stream`/`suggestions.stream` → `facet`; `proposed_terms.by_stream` → `by_facet`. DSL: `assign`/`stream(name, tier:, keys:)` → `assign`/**`facet(name, tier:, terms:)`**. Query API: `keys_for`→`terms_for`, `allowed_keys`→`allowed_terms`, `required_keys`→`required_terms`. `config.tending_streams` → `tending_facets`.
- The quality-score **`Enliterator::Facet`/`Facets`** (a named score + signals, e.g. completeness) → **`Enliterator::Measure`/`Measures`** (`enliterator_facets` table → `enliterator_measures`). This frees "facet" for its true sense; completeness is a *measure*, not a classification facet. The state key `facets:` → `measures:`.
- Claim **keys** → **terms** in the controlled-vocabulary sense (the `Claim.key` *column* stays — key/value is a natural pair; the term IS the key).

## Surface copy reframed in LIS terms
- Requests → "**Authority control** — the controlled vocabulary, reviewing itself": the model PROPOSES a term (doesn't invent off-list); a term earns its place by recurring (literary warrant); synonyms shown as **USE/UF** references.
- Status → "the collection's **finding aid**, maintained for itself" (scope & content, controlled vocabulary, connection graph, tending health).
- Chat → "a **reference interview** with the collection" (iterative, citation-following).

## Homonym discipline (why this was surgical, not a global sed)
"stream" is overloaded: the facet concept AND HTTP/SSE streaming (`conversation#stream`, `converse(stream:)`, `stream_raw`). Word-boundary perl (`\bstream\b`) renamed the facet sense on pure-facet files while leaving `upstream`/`streaming`/`streamUrl`/`conversation_stream_path` and the converse streaming flag untouched; the 4 adapters were hand-edited (tend's `stream:` → `facet:`, converse's `stream:` kept). `.keys` (Hash method) meant `keys→terms` was colon-targeted (`keys:`), never bare.

## Migrations (additive, reversible; data preserved)
`RenameFacetsToMeasures` (rename_table), `RenameStreamToFacet` (rename_column ×2), `RenameByStreamAndFacetIndexes` (by_stream column + two stale index names). Applied to dummy + HSDL dev with all data intact (994 visits, 500 measures, approved terms).

## Done = all of (this phase):
- `Contract→Vocabulary`; `stream→facet` (columns, DSL, query API, config, prompt); quality `Facet→Measure` (model/registry/table); `keys→terms` (DSL + query API + UI).
- Surface copy reframed (authority control / finding aid / reference interview / USE-UF).
- HSDL initializer migrated (`facet`/`terms:`/`Measures.register`); HSDL dev migrated.
- 254 specs green throughout (no behavior change). README + this section updated.
- Deferred (aware-not-now): LRM/WEMI (Work/Expression/Manifestation/Item) on the record; SKOS/BIBFRAME emission; syndetic structure (BT/NT/RT) unifying vocabulary + the context tree.

# v0.13 — Contexts (nested enliterated collections)

A collection is rarely one thing — HSDL is a federation (theses, 35K CRS Reports, 1K Executive
Orders, ~100 cross-cutting topical Lists). v0.13 makes **context** a first-class, nestable dimension:
a context is a faceted LENS (Ranganathan; the finding-aid principle — an item understood through its
place in the hierarchy plus its own description). An item belongs to the root implicitly and to any
number of labeled sub-contexts (M2M); each context declares its own facets, inheriting its ancestors';
claims/visits/suggestions are context-scoped and read cumulatively up the ancestry.

## Design rules (the four that make it coherent)
1. **NULL is the root scope.** A root Context row anchors the tree for UI/membership only; tending at
   root writes `context_id NULL` — exactly where all pre-v0.13 data already lives (no backfill needed
   for back-compat). Cumulative reads use `[nil, *path_ids]`; the root UI view = the unfiltered union.
2. **Declaration location = tending scope.** A facet tends in the context whose policy block declares
   it (the A′ mechanism: intrinsic/root facets tend once at root; interpretive facets per context).
   `tend_context` runs exactly a context's own facets.
3. **Neighbors are context-scoped.** Within a context, retrieval (tending neighbors AND chat) is
   restricted to the context's MEMBERS — the context IS the neighborhood; an EO reads against other
   EOs, not the undifferentiated corpus. Root keeps corpus-wide.
4. **Governance writes down, reads up.** Verdicts/claims write to their own context; resolved keys,
   approved vocabulary, and claim reads resolve `[nil, *path_ids]` — root/legacy verdicts inherit
   down; a sibling's never leak over. ONE rule for claims and governance alike.

## 1. Schema + models
`Enliterator::Context` (ancestry; unique `key` slug joins the policy; `path_keys`/`scope_ids`),
`ContextMembership` (polymorphic M2M, string member_id for uuid hosts), nullable `context_id` FKs on
claims/visits/suggestions with composite reconcile/health indexes. `ancestry` becomes a gem dependency.

## 2. Per-context facet policy + context-scoped tending
Policy `context "key" do … end` blocks scope `facet`/`assign` (root registries untouched outside
blocks — a contextless policy is byte-identical to v0.12); lookups take `path:` (descendant wins):
`tier_for/terms_for/allowed_terms/required_terms/allowed_tiers`, plus `facets_for(path)` and
`facets_declared_in(key)`. (NOT `context_cap` — the LLM window cap; unrelated word.) `Vocabulary.for
(facet, context:)` reads approvals up the path. Visitor threads context end-to-end: Visit/Claim/
Suggestion stamping, `live_claim_for(key)` scoped to the tending context (the reconcile chokepoint —
the same key in a sibling is a DIFFERENT claim), member-scoped `nearest_neighbors`, path-scoped
suppression, `literacy_state` labeling inherited claims by context. `Suggestion.resolved_keys
(context:)` + batch verdicts take `context:`. Tendable: `tend!(facet:, context:)`,
`place_in_context!`, `assert_claim!(context:)`.

## 3. The switcher + the sixth surface
ApplicationController resolves `?context=` (one-shot → cookie; unknown keys log + fall back to root);
inline nav switcher hidden when no tree is seeded. `Synopsis.build(context:)` — effective facets,
path-scoped counts, per-context gaps. Chat converses through the lens (scoped retrieval + claims).
Requests shows the context's OWN pending queue (a WRITE surface shows what a verdict resolves);
considerer takes `context:`. Settings shows the merged effective policy with declaring-context chips.
NEW `/enliterator/contexts`: the tree — own facets, members, per-scope claim/visit counts.

## 4. Host seating (HSDL) + rake
HSDL initializer: root facets (summary, connections) + `context` blocks — chds-theses (significance,
authorship), crs-reports (policy_analysis: issue_for_congress/policy_options/affected_agencies/
legislation_referenced), executive-orders (directive: eo_number REQUIRED/issuing_president/
agencies_directed/legal_authority; legal_relations: supersedes/implements), election-security
(inherits only — a topical lens). `enliterator:seed_contexts` (HSDL, idempotent): tree + bulk
memberships (1,327 theses / 35,020 CRS / 1,026 EOs / 82 election-security) + facet-following backfill
(488 visits, 1,322 claims, 203 suggestions → chds-theses). Engine rake `enliterator:tend_context
CONTEXT=key [LIMIT=n] [FACET=f]` (rule 2; staged/non-overlapping); `enliterator:consider CONTEXT=key`.

## Validated on the real collection
Divergence: EOs tended in-context produced `eo_number=13268`, `issuing_president=George W. Bush`,
`legal_authority=IEEPA/NEA`, and **supersedes=["13129"]** — the EO→EO legal supersession graph, live
(claims a thesis lens cannot produce); CRS produced `issue_for_congress`/`legislation_referenced`
(PATRIOT Act §1016(e), PDD-63)/`policy_options`. Cross-cutting: EO 13848 (foreign-election-
interference sanctions) lives in BOTH executive-orders and election-security; sibling isolation
verified live (an EO-context claim is invisible from election-security's scope).

## Done = all of (this phase):
- Substrate (models/migrations/policy/visitor/governance) + switcher across all surfaces + /contexts.
- Specs green at 281 (was 254; +27): context model/policy/tending/vocabulary/verdict-isolation/requests.
- No-context paths byte-identical throughout; flat installs see no UI change.
- HSDL seated + divergence/cross-cutting validated on real data (HSDL-side changes gated, uncommitted).
- Deferred: per-scope tended-count semantics on inherited facets (currently path-scope counts);
  promoting genre-intrinsic claims to root; the cross-record flywheel; SKOS/BT/NT unification.

# v0.14 — The Compounding Proof (trajectory, judge, supervised experiment)

The engine's central thesis — the tenth visit is smarter than the first — was asserted (About),
structurally supported (provenance chains, reconcile ops, state threading), and never MEASURED. v0.14
is the loop's final supervised exam and the deliberate end of the hand-cranked era: it proves (or
disproves) the thing automation would repeat, and its report is the GATE for v0.15 (the heartbeat).
Failure modes hunted by name: FREEZE (all NOOPs — compounding is hollow) and CHURN (cosmetic rewrites
dressed as UPDATEs — worse, because it looks like compounding).

## 1. `Enliterator::Trajectory` (pure-read longitudinal service)
- `state_at(record, time, context:)` — the claim set live at any past moment, reconstructed from the
  supersession chain: live at T iff created_at<=T AND NOT(superseded by a claim created<=T) AND
  NOT(a DELETE tombstone — status superseded, no successor — updated_at<=T). (Tombstone time ≈
  updated_at; no dedicated column — adequate under single-writer tending, noted in the docstring.)
- `for(record, facet:, context:, last:)` — per facet (a claim's facet = its creating visit's), the
  ordered APPLIED visits with ops (from Visit.reconciliation), confidence, state-at-visit, and the
  per-key diff from the prior state (added/changed(from→to)/deleted) with a CHURN flag: bigram-Dice
  similarity of old vs new > 0.85 ⇒ an update that didn't really update.
- `compounding_summary(records, context:)` — per pass-index rollup: op mix, mean confidence,
  churn_rate (churned/updated), novel_rate (added/total ops). The experiment report's substrate.

## 2. `Enliterator::Trajectory::Judge` (the semantic check)
Blind pairwise comparison via the considerer's `#decide` plumbing: the record snippet + two claim-
states labeled A/B in RANDOMIZED order (no before/after/earlier/later language anywhere in the prompt
— spec-enforced; the de-blinding map stays local). Schema: winner/richer/more_accurate ∈ {A,B,tie} +
rationale + confidence → de-blinded `{later_wins: true|false|nil(tie), …}`. Tier = considerer_tier
else ladder top; Null adapter ⇒ nil verdict (soft degrade, never raises — judging writes nothing).
Churn (string) and judge (semantic) cross-validate: high churn + ties ⇒ cosmetic; low churn +
later-wins ⇒ real deepening.

## 3. "Understanding over time" (status drill-down — the demo surface)
For each facet with >1 applied visit: a table — rows = claim keys, columns = applied visits
(chronological, capped 6), cell = the value AT that visit, CHANGED cells highlighted, with per-visit
op-chips (+a ~u =n −d) and confidence in the header. Absent with a single visit (byte-identical page).

## 4. The experiment (HSDL-side, gated)
`lib/tasks/enliterator_compounding.rake`: `setup` (deterministic cohort — 10 theses + 5 CRS + 5 EOs,
pass-1 fill, split into ARM A/enriched + ARM B/control, tmp/enliterator_compounding/cohort.json);
`enrich` (tend K=3 nearest untended context-mates of each arm-A record — the SURROUNDINGS are the
variable: a re-visit has no reason to be smarter unless neighbors/vocabulary/contexts changed);
`pass` (re-tend the cohort, bypassing the staged-first-pass done-skip — deliberate); `report`
(Trajectory rollup per arm + Judge first-vs-latest → markdown: op mix per pass per arm, churn rate,
confidence trajectory, judge later-wins %, and the headline ARM A − ARM B delta). Run shape:
setup → enrich → pass → enrich → pass → report, all supervised.

## Done = all of (this phase):
- Trajectory + Judge + the drill-down surface; specs green at 296 (was 281; +15: trajectory 9,
  judge 4, status surface 2).
- The supervised experiment run on the real collection; the report + an explicit v0.15
  recommendation (heartbeat trigger the data supports, or the fix re-visiting needs first).
- README (trajectory + experiment), About living-doc (measured compounding + colophon v0.14),
  CLAUDE.md current-state.

## v0.14 findings (the supervised run, 2026-06-09 — cohort 20, 3 passes, 66 enrichment tends)
- **Instrument calibration caught by supervision:** the first judge run scored later-wins 95% —
  an artifact: claims land moments AFTER their Visit row's created_at, so "state at visit 1" was
  EMPTY and anything beat nothing (the judge's readable rationales exposed it). Fixed with
  `Trajectory.state_after` (post-reconcile boundary = next applied visit on the facet, else now);
  regression-spec'd with the real-data write pattern. Calibrated numbers below.
- **No churn.** Zero gratuitous rewrites across both arms (churn_rate ≈ 0; summary NOOPs at
  conf ≈ 0.95 everywhere). Re-visits are SAFE — the reconcile contract holds under repetition.
- **No free compounding from re-reading.** Unchanged surroundings ⇒ NOOP (arm B pass 3: 0 adds,
  novel_rate 0). The tenth visit is NOT smarter by staring at the same text again; the judge ties
  dominate (identical states), later-wins ~17.5% both arms, arm delta ≈ 0 at this n.
- **Deepening tracks surroundings-change** — visible in ops (pass-2 adds; the only context-facet
  adds were arm-A significance; connections grew with the corpus) but the A/B judge delta was
  nulled by a DESIGN FLAW we caught: root facets use corpus-wide neighbors, so arm A's 66
  enrichment tends contaminated arm B's root-facet re-reads. Clean A/B isolation needs
  context-facet-only comparison or per-arm corpora; n=20 × 2 re-passes is small.
- **Where the value is: the frontier.** Pass 1 minted 158 claims; passes 2–3 added 13. First
  attention dwarfs re-attention at this collection's maturity.

**The v0.15 gate verdict: event-driven heartbeat, not wall-clock.** Blind scheduled re-tending is
safe but mostly NOOP spend. Automation should (1) prioritize the UNTENDED FRONTIER (35K CRS docs),
(2) trigger re-tends on CHANGE — new context-mates tended, vocabulary approvals, record text
change — with `stale_after` kept only as a slow safety-net sweep, (3) carry a per-cycle spend cap
+ the trajectory surface as the standing watch instrument.

# v0.15 — The Heartbeat (event-driven tending; the end of the hand-cranked era)

Every version through v0.14 was hand-cranked deliberately — supervision while the loops were
built up. v0.14 was the supervised exam, and its verdict SPECIFIES the automation rather than
merely permitting it: re-visits are safe (zero churn) but re-reading unchanged surroundings is
pure NOOP spend; deepening tracks SURROUNDINGS-CHANGE; first attention dwarfs re-attention.
So v0.15 is event-driven, not wall-clock — and supervision is replaced by two instruments:
a hard spend cap (enforced on actuals) and an auditable cycle ledger.
One heartbeat = one full metabolic cycle: **plan → tend → consider → ledger**.

## 1. `Enliterator::Heartbeat` (the model IS the scheduler — the cycle is a record)

- `Heartbeat.plan(budget:)` (→ `Heartbeat::Planner`, PURE read): a prioritized, budget-bounded
  work queue. **Budget envelopes, not strict priority**: a change envelope
  (`budget × heartbeat_change_share`, default 20%) ordered **source_change → neighborhood →
  vocabulary** (correctness before deepening); unused change budget spills to the **frontier**
  (first attention — ~10× claims/dollar per v0.14); the `stale_after` **sweep** is demoted to
  leftovers only. Plus the **horizon math** ("frontier: N remaining ≈ M cycles at this budget")
  so the budget is an owned decision, not an accidental schedule.
- `Heartbeat.beat!(execute: :sync|:enqueue, budget:, skip_consider:, force:)`: opens the ledger
  row FIRST (an unfinished row < 6h **is the overlap lock** — `Heartbeat::Overlap` raised;
  FORCE recorded), executes, runs the considerer per scope with open requests, finalizes.
  Sync (default; the supervised mode) enforces the budget on **ACTUAL** tokens summed from the
  cycle's own visits — the cap is a guarantee, not a guess. Item failures continue; a cycle
  whose first 5 items all fail aborts as a misconfiguration. Enqueue mode carries a
  **drain-deficit check** (previous cycle's enqueued count vs visits that landed) so a dead job
  queue can't become a silent no-op factory.

## 2. The three change triggers — all anchored to lane `MAX(started_at)`

NOT `finished_at`: text + vocabulary are read at visit START; a visit finishing after a change
must not mark its record caught-up (the mid-visit race, closed). Root lanes use explicit
`context_id IS NULL` — `last_tended_at(context: nil)` is UNFILTERED, a named trap, avoided.

1. **source_change** — host `updated_at` > lane last start (set-based join), or the host's
   `heartbeat_source_changed` callable (for touch-chain/backfill-noisy hosts).
2. **neighborhood** — ≥ `heartbeat_neighbor_threshold` (3) lane visits after the record's last
   (one window scan: `total − my_row_number`; visits, not distinct mates — a documented proxy).
   Context lanes ONLY (at root the corpus-wide neighborhood would re-trigger everything forever);
   **suppressed while the lane's frontier is non-empty** (finish the shelf first); per-record
   cooldown `max(stale_after/10, 1.day)`; quiet-lane pre-gate once a finished beat exists.
3. **vocabulary** — per-lane vocabulary version `V = MAX(updated_at)` over approved suggestions
   visible up the path (exactly `Vocabulary.for`'s scope); candidates whose lane start < V,
   oldest first — a resumable cursor with ZERO new state (one re-tend catches a record up to all
   approvals at once); wave drain arithmetic logged.

Frontier/sweep enumeration is SQL anti-joins with LIMIT (never the in-memory done-set or the
NOT IN id-array); per-lane quotas + one redistribution pass + a tiny-budget greedy fallback;
24h failure backoff everywhere. Estimation: trailing-window succeeded tokens ÷ applied visits
(escalation chains price themselves in), fallbacks logged.

## 3. Provenance + surfaces

- Visits carry `heartbeat_id` + `reason` (NULL on every manual tend — byte-identical when
  unused). PROV: the Heartbeat is the Activity that informed the Visit; enqueue-mode actuals
  stay derivable via `Visit.where(heartbeat_id:)`.
- `rake enliterator:heartbeat` — BUDGET= PLAN=1 ENQUEUE=1 FORCE=1 SKIP_CONSIDER=1; sync default.
- Settings: the Heartbeat panel (knobs + last cycle; "never run" until adoption). Status: the
  next-cycle preview + horizon, **gated behind adoption** (no ledger rows ⇒ byte-identical page,
  zero planner queries).
- Migrations (reversible): `enliterator_heartbeats`; visits `heartbeat_id`+`reason`; the lane-scan
  index `[context_id, facet, created_at]`.

## Honesty notes
- The **vocabulary trigger is the one unmeasured trigger** (v0.14 tested neighbor-change only) —
  watch its first real wave through the trajectory surface.
- `updated_at` is an approximate source-change signal (override point provided; per-visit source
  digests deferred).
- The token budget is tier-blind (a free on-prem token = a paid token); dollars stay derivable
  from per-visit tiers + `Spend`'s price_map.
- The considerer's own LLM tokens have no usage surface (`decide` returns none) — recorded as
  outcomes only, not invented numbers. Enqueue mode's considerer lags one cycle (recorded on the row).
- Job-signature rollback caveat: 5-arg TendingVisitJobs in a queue won't deserialize under a
  pre-v0.15 engine.

## Done = all of (this phase):
- Heartbeat model + Planner + Plan; provenance plumbing; rake; surfaces. 43 new examples
  (provenance 3, job 3, plan 22, beat 11, surfaces 4); **341 green**.
- Supervised first cycles on HSDL (PLAN=1 read, then a small sync beat watched live) before any
  host scheduling — automation is adopted by the host only after the cycles earn trust.
- README (heartbeat), About living-doc ("the pulse" + colophon v0.15), CLAUDE.md current-state.

# v0.16 — The Pulse Monitor (trigger + watch a heartbeat in the browser)

Before anything time-based is wired, the heartbeat gets a face: a page that triggers one cycle
and shows it live. The demo surface (press the button, watch the collection learn) and the
supervised on-ramp to host scheduling. Everything the monitor renders derives from provenance
that already exists — the open ledger row plus the visits it stamps as they happen. **No new
state, no migrations, no websockets** — a 2s poll.

## 1. Model: the trigger seams
- `Heartbeat.open!(mode:, budget:, force:)` extracts beat!'s synchronous half (validate →
  **advisory lock** → overlap check → plan → row create) and returns `[row, plan]`; `beat!` is
  recomposed on top, byte-identical. The check→plan→create sequence holds
  `pg_advisory_xact_lock(hashtext('enliterator_heartbeat'))`: two concurrent triggers (two
  browser tabs, a button + a rake) would otherwise both pass the unfinished-row check during the
  seconds the plan scan takes and BOTH open cycles — doubled spend, the exact failure the
  instrument exists to prevent. Engine is Postgres-only; the lock needs no migration.
- `row.execute_async!(plan, skip_consider:)` runs `execute!` on a named background thread under
  `Rails.application.executor.wrap` and **returns the Thread**. Deliberately NOT ActiveJob: a
  dead worker would make the button a silent no-op; the thread works in every host. The outer
  rescue covers the one path execute!'s own handling misses (finalize! itself failing): log +
  best-effort `update_columns(finished_at:, error:)` — an open row can never stop moving
  unexplained.

## 2. The page (`/heartbeat`, nav link added)
- **Plan + trigger mode**: reason chips, per-lane work table, est vs budget, the horizon line,
  planner notes; budget input (server-side clamp: blank/0 → config default; anything larger
  clamps DOWN to it); Beat now disables to "planning…" (the POST holds the plan scan).
- **Monitor mode** (predicate = the lock's: unfinished AND < 6h — an OLDER open row is crash
  evidence in the recent table, never a monitor trap): progress bar by **items** (distinct
  record+facet+context tuples; escalation pairs and failed visits don't inflate; the budget is a
  cap, not a target, so tokens are adjacent text), per-reason fill chips, a live visit ticker,
  "running considerer…" when items complete but the cycle hasn't closed, a stall banner with an
  inline force-form after 5 quiet minutes, a poll loop that survives server restarts. The finish
  (or abort) renders INLINE before the reload.
- **Global, explicitly**: the heartbeat works every context in one budget; the page says so —
  the nav's context selector scopes Chat/Status/Settings/Requests, never this surface.
- `GET /heartbeat/pulse/:id` — by row id, never "latest" (a forced second cycle must not switch
  the subject under a watching monitor). Finished payload carries executed/warnings/considerer.

## Accepted limitations (named)
- **Dev code-reload waits while a cycle runs** (the thread holds the executor's running share
  for the cycle's minutes) and the thread holds one AR pool connection. Acceptable for the
  supervised/demo surface; production pacing belongs to the host scheduler + ENQUEUE.
- A server restart kills the in-process cycle; the row stays open as crash evidence, the
  monitor's stall banner says so, and force starts the next cycle. This is the designed
  recovery story, surfaced where it happens.
- Mid-cycle `warnings` live in memory until finalize — the pulse only carries them on finish.

## Done = all of (this phase):
- open!/execute_async! + controller + page + nav. 19 new examples (open/async 6, page 10,
  chat-scope 3); **360 green**. (Rides with: the chat scope banner — the context cookie was
  invisible on /chat; found by Jeremy as a user.)
- Live on HSDL: a browser-triggered cycle watched end-to-end; second-tab overlap refusal.
- README (surfaces), About (surfaces grid + the pulse can be pressed), CLAUDE.md current-state.

# v0.17 — Condition (the collection shelf-reads itself)

"Item in the card catalog but can't be found?" is digital preservation's ladder — **present →
intact → extractable → intelligible** — and this version builds it IN to preservation's own
practice: inventory/shelf-reading, fixity & format validation (the JHOVE/PREMIS function),
extraction quality, and condition reports with treatment proposals written by a conservator.
The economics close a loop: every rung a record fails at is tending spend not committed.
Rung 4 is never probed — **the tending loop is the instrument**, and the residue (sound
condition, repeatedly read, zero derived claims) is its reading.

## 1. `Enliterator::Condition` — probes, survey, piles, residue
- Host-registered probes (`Condition.register(:availability) { |record| {ok:, code:, signals:,
  remediation:, note:} }`); `gates_tending: true` marks the probe that answers "can the ENGINE
  read it." NO short-circuit: a dead link with cached text still passes legibility — the library
  kept a surrogate. nil return = not applicable (multi-model hosts).
- Survey cadence is its own (`survey_batch!` + `upsert_all`), never per-tend —
  **`Measures.register` now RAISES on the condition namespace** (a per-tend measure would
  silently clobber the survey and corrupt the gate).
- Rollup bands, exact: **1.0 sound / 0.5 degraded** (patron-side failures only) / **0.0
  untendable** (a gates_tending probe failed). Probe ERRORS are instrument failure: nil score,
  excluded from the rollup, presumption of tendability.
- **Signature** = sorted `probe:code` pairs joined `+`, computed at survey time, stored on the
  rollup's signals — piles are one GROUP BY; no rungs or error text in the string (registry
  renumbering and message drift must never orphan a treatment).
- Locked `source_status` claim at **untendable only** by default (`condition_claim_scope :all`
  opts degraded in — at a prompt-token cost on every future visit, named below); new
  `Tendable#retract_claim!` withdraws the note when a record recovers. Resolution is MEASURED.

## 2. The gate + the shelf-read cadence
- The untendable predicate is appended to **all five** candidate queries — frontier,
  source_change, neighborhood, vocabulary, sweep. Not just frontier: a host's link-checker
  flipping a status column bumps `updated_at`, and an ungated source_change would re-tend the
  records the survey just condemned (spec-pinned with exactly that scenario). Rendered only once
  a survey has ever run — non-adopters keep byte-identical SQL. The plan names its exclusions.
- `execute!` runs the **survey phase first** (time-boxed, `heartbeat_survey_budget_ms`; outcome
  on the ledger's `survey` column; a survey failure warns and the cycle continues) and gates each
  item at execution time (the plan was frozen at open!; this cycle's own survey may have
  condemned a planned record since).
- `rake enliterator:survey` = the retrospective conversion (initial inventory, to completion);
  the heartbeat phase is the ongoing shelf-read.

## 3. `Enliterator::Conservator` + the report
- The Considerer pattern on the collection's condition: one decide call over the failure piles
  (+ the residue as synthetic pile `rung4:never_understood`), writing per-pile **diagnosis** and
  **treatment** for collections staff. The probe's `remediation` is fed in as ground truth — the
  agent augments and prioritizes, never invents host procedures. Positional ids in prompt AND
  schema (the signature is the upsert key; a reworded echo must never mint a phantom row).
  Delta gate: the LLM runs only when a pile changed; sightings always recorded.
- `enliterator_treatments` has **no status machine**: piles are LIVE — a fixed record passes its
  next survey and leaves its pile; rows persist as the standing explanation.
- Status gains the **conservation report** (adoption-gated): coverage, piles with the probe's
  remediation and the conservator's treatment as visibly distinct columns, the residue, and the
  untendable total with its queue-exclusion effect. Settings names the probes + knobs.

## Named decisions
- Condition measures enter `literacy_state` prompts post-adoption (deliberate — arguably useful
  context; rows only exist for adopters).
- The Visitor blank-text guard is **explicitly deferred**: the legibility probe is the opt-in
  guard; an engine-level guard would change unadopted behavior.
- Degraded never affects scheduling in v0.17 (a future `ORDER BY` option, one line, not taken).
- Flapping sources chain claims (assert → retract → assert) — accepted; the piles'
  last_seen_count will reveal whether damping is ever needed.
- The default `:completeness` measure counts locked claims as "having a claim" — a pre-existing
  wart v0.17 amplifies (source_status counts); noted, not fixed here.
- Conservator/considerer LLM token usage remains untracked (no usage surface on decide).

## Done = all of (this phase):
- Condition + Conservator + gates + survey lane + report; migration (treatments, survey-ordering
  index, partial untendable index, heartbeats.survey). 33 new examples; **393 green**.
- HSDL probes (availability ← url_status; integrity ← docling_status; legibility ← text
  presence) + supervised `enliterator:survey` + a beat with the survey phase live.
- README, About ("the conservation report" — living-doc rule), CLAUDE.md.

# v0.18 — The Audit (accuracy, measured)

Since v0.5 the cheap tier's claims have routinely carried confidence 1.0, and nobody had ever
checked whether they were TRUE. Before the heartbeat's budget scales, accuracy must be measured.
LIS frame: **quality review** (revision of cataloging) — a distinct librarian function from
Requests' authority control, with its own surface and write path. The instrument MEASURES; the
only acting is human. (This version also carried **Phase 0**: the launchd plist that beats HSDL
nightly at 3:30 — the heartbeat's own adoption, a separate trust decision from the audit's.)

## 1. The register + the examiner
- `enliterator_audits`: one row per examination of one claim (examiner or human; multiple per
  claim is the point). Verdicts: supported / unsupported / contradicted / **unverifiable** (the
  honest exit for neighbor-grounded claims — excluded from the accuracy denominator). Rows carry
  the source digest/chars/truncated they were rendered against, the examiner's corrected_value
  PROPOSAL, and corrected_claim_id once a human mints the fix. Claim FK cascades (an audit
  without its claim is uninterpretable; destroying host records shifts the rate — named).
  `Claim.review_state` (unused since v0.1) deliberately NOT repurposed.
- `Audit.sample(n)`: stratified uniform-random per **facet × tier** (tier NULL → "unknown";
  strata global, context is a drill-down label) over the anti-join: live, engine-derived
  (`visit_id IS NOT NULL` — host claims aren't the model's accuracy), unlocked, never audited.
- `Audit::Examiner`: one quality-tier decide per claim, BLIND to tier/confidence/attribution/
  siblings, grounded in the SAME full `enliterator_text(facet:)` the tend read
  (`audit_source_chars` ceiling, default 24K, truncation stamped — a snippet-bound examiner
  yields false "unsupported" for deep-grounded claims, the inverse of the failure this version
  exists to catch). The term's controlled meaning resolves in the claim's OWN context. Verdict
  definitions verbatim in the prompt; phrasing/style are never grounds for unsupported.

## 2. The rates
- `Audit.accuracy` — per facet × tier. **Headline = the PROCESS rate: audits never age out**
  when their claim is superseded. The censoring argument: every heartbeat cycle replaces audited
  claims with new unaudited ones from the same tier, so a live-only rate "improves" with zero
  new evidence — re-tending must not be a way to launder the number. `live` is the secondary
  stock count. Where a claim has both verdicts, the **human wins** (the anchor is the only
  independent ground truth).
- `Audit.anchor_agreement` — BINARY (supported vs defective; unverifiable pairs excluded);
  no % below 10 overlaps; and the load-bearing line: **humans overruled examiner-supported x of
  n** — the false-supported rate that bounds trust in the whole headline.

## 3. The ride-along, the on-ramp, the surfaces
- `audit_phase!` after the conservator. **`heartbeat_audit_sample` DEFAULT 0 = OFF** — setting
  it non-zero IS the adoption act (quality-tier spend must never start on a gem upgrade; the
  spec pins byte-identical at the default). Survey-style failure semantics; a Null examiner is
  a VISIBLE skip (ledger + warning + the panel says "examiner unavailable"). Audit spend is
  OUTSIDE the tending token budget — the v0.15 guarantee covers tending only.
- `rake enliterator:audit N=` — every loop gets a hand-crank before it rides; prints each
  verdict + rationale so the examiner's judgment is READ first.
- **/review** (nav: Review): the human anchor's queue — ~1/3 examiner-supported by design (the
  false-supported detector), doubted first; per row the source snippet with a digest-driven
  "source changed since examination" flag; actions confirm / overrule (chosen, never imputed) /
  **correct** → `Tendable#correct_claim!` — NOT assert_claim! (in-place mutation would rot the
  audit under its own verdict): a NEW locked verified human-attributed claim in the SAME
  context, derived from the one it corrects, then superseded; reconcile NOOPs it forever and
  literacy_state feeds the fix back. `Claim::AlreadySuperseded` guards the race with a re-tend.
- Status: the Accuracy panel (adoption-gated).

## Honesty notes
- The examiner shares the tender's worldview — correlated errors (quality-on-quality is the
  model family grading itself). The human anchor is the only independent ground truth.
- Verdicts are rendered against the CURRENT source; a changed source can flip a once-faithful
  claim — a true catalog defect, not necessarily a tender error (the digest distinguishes).
- Headline = process rate; the live-only stock rate is censored by supersession.
- Small n: at 10/cycle expect weeks to n≈30 per cell — the panel shows counts and withholds
  rates honestly while collecting.
- Human-corrected (visit-NULL) claims are invisible to the residue discriminator and trajectory
  facet timelines (named, not fixed).
- Audit spend is untracked by the token budget (no usage surface on decide — same as the
  considerer and conservator).

## Done = all of (this phase):
- Phase 0: the pacemaker plist loaded (first unattended beat 3:30 AM); supervised week of
  morning ledgers — a SEPARATE trust decision from the audit instrument's.
- Register + examiner + rates + ride-along + rake + Review + panel. 28 new examples; **422 green**.
- HSDL: initializer sets heartbeat_audit_sample 10; `enliterator:audit N=25` supervised with
  rationales read raw; one real claim corrected end-to-end on /review.
- README, About (living doc), CLAUDE.md.

# v0.19 — The Component Standard (one quiet system)

Jeremy's directive, reviewing the Requests queue: the verdict UI read as clutter, the content
columns truncated mid-sentence, and styling had drifted page-by-page. "We don't want to add a
style system dependency but we should standardize our approach to components and style to
ensure long term success." Also: the context switcher belonged NEXT TO the things it scopes.

## 1. The inventory (what six versions of page-local styling drifted into)
~6 unrelated button treatments; the accent "live" badge hand-inlined in 4 places; warn chips
inlining a raw `#fdeceb` literal in 3; every select/input repeating the same inline rules;
the `h2 — subtitle` pattern re-styled on every page; three bespoke summary strips.

## 2. The standard (inline, dependency-free — hard rule 2 untouched)
- **Tokens** (`:root` in the layout): color (`--warn-soft` kills the literal), an 8px spacing
  rhythm, radii, type scale.
- **Components, defined once in the layout `<style>`**: `.btn` + affirmative/primary/
  destructive/sm (hover, `:focus-visible`, disabled); `.field`; `.chip` + `.chip.warn` +
  `.chip.tier`; `.badge-live`; `.subtitle`; `.strip`; the quiet table and `.card`.
- **The rule, documented IN the style block where it can't drift**: new pages compose from
  these; a page's own `<style>` is for page-specific layout only; reach for a token, never an
  inline color.
- Existing class names were only ADDED to, never renamed — the inline JS hooks
  (`#ctx-switch`, Chat's thread/bubble/provenance, Heartbeat's pulse monitor) are load-bearing.

## 3. The nav (scope precedes what it scopes)
Brand tagline removed; `#ctx-switch` moved LEFT, into a `.nav-scope` group between the brand
and the context-scoped destinations (Status · Chat · Requests …), fenced by a hairline that
renders only when a switcher exists. The selector now visually governs the items whose content
it changes. Settings/About push right.

## 4. Requests, redesigned (the queue is a decision, not a table)
The 6-column pending table became per-term cards: key + facet + pressure as the header line;
rationale / example / considerer verdict given room (display caps 120→220, 70→140, 90→160 —
copy untouched); actions right-aligned as one coherent group — Approve (affirmative) / Map
(field + button) / Reject (destructive). Collapses to one column under 640px. Every form post,
param, and label byte-identical.

## Honesty notes
- Chat and the pulse monitor stay page-local by design: their classes are live JS hooks and
  their layouts are bespoke; both consume the shared tokens so they read as one system.
- The flat-install spec caught a real leak: putting `#ctx-switch` in the always-rendered style
  block surfaced the string on hosts with no context tree. The selector is styled via its
  parent group; the id exists only on the conditional element. (The spec suite as UI guard.)
- AA contrast verified on every token pairing (tightest: muted-on-chip 4.69); 390px checked.

## Done = all of:
- Layout token/component layer + 7 pages swept; before/after sets in `tmp/ui-pass/`.
- Suite green (no copy changes — the page-text pins held).
- SPEC, README (the surface list had drifted: eight surfaces, Review was missing), About
  colophon.

# v0.20 — The Prepared Finding Aid (pages stop censusing the stacks)

Jeremy, navigating: "second per page." Measured: worse — Status ~18s, Heartbeat ~13s, 97%+ of
it SQL. The diagnosis (EXPLAIN ANALYZE, live HSDL): both pages ran `Heartbeat.plan` — the full
planner — synchronously on every view, and the planner's frontier fetch carried a query-shape
trap. Requests carried a 331-query N+1. The principle that fixes it is the field's own:
**a finding aid is a prepared document with a revision date** — nobody re-inventories the
stacks each time the binder opens.

## 1. The query trap (and the 23× fix)
`doc_meta.id` is a uuid; `visits.tendable_id` is a string — the frontier anti-join casts
`id::text`, an expression Postgres has no statistics on. PG estimated 1 row would survive the
first anti-join (actual: 314,559) and planned the failure-backoff `NOT EXISTS` as a correlated
nested loop: 314K index probes, 24.5M buffer reads, ~9s per root lane. The fix: the backoff
exclusion became a NON-CORRELATED `NOT IN` subquery — a **hashed SubPlan**, built once and
hash-probed per row, immune to the misestimate. Measured 8,980ms → 384ms. (Safe:
tendable_type/tendable_id are NOT NULL, so NOT IN's null-poisoning can't bite. The membership
branch uses the row-constructor form.) This still matters after §2: `open!` re-plans every
real beat, and the nightly cycle pays the census where it belongs — at 1:30 AM.

## 2. The previews read the ledger
- `Heartbeat::PreparedPlan` — a ledger row's `planned` jsonb behind the same interface the
  views render (`counts/lane_counts/est_total/budget/warnings/horizon_line`), plus `work?` and
  `as_of` (the revision date). `Plan` gains `work?`/`as_of(nil)` — the views are polymorphic
  over the plan's source and never branch on it. Spec-pinned round trip: a PreparedPlan built
  from `Plan#to_ledger` renders identically to the live plan it was written from.
- Status: the preview wraps the LAST ledger row — never a live census (spec:
  `Heartbeat.plan` is not received). The "plan as of cycle #N, <time>" line is the honesty.
  Also fixes v0.15's unguarded plan-while-a-cycle-runs case.
- Heartbeat page: prepared when any cycle has ever run; the LIVE census remains only for a
  host with no preparation to read (first-run — the page must still show what the first beat
  would do). `open!` re-plans authoritatively at beat; `rake enliterator:heartbeat PLAN=1`
  stays the on-demand inventory.

## 3. The rollups come prepared too (Rails.cache — Jeremy: "Solid Cache usage is viable")
- `Synopsis.build` serves from the host's `Rails.cache` (Solid Cache on HSDL dev, Redis in its
  prod, memory or null anywhere else — a null store recomputes, byte-identical); `assemble` is
  the uncached computation. Key carries the latest heartbeat id (every cycle republishes the
  portrait) + 5-minute TTL (covers manual tends between cycles). The chat grounding reads
  through the same cache.
- `Condition.report` — the conservation numbers (surveyed/total/untendable/piles/residue),
  same key discipline. **Treatments are deliberately NOT cached** — the conservator's and the
  curator's writes must show immediately; the controller merges them live.
- Kept LIVE deliberately: the accuracy panel (cheap; /review verdicts must reflect at once).
- The memory-store spec caught a real serialization-boundary bug on first run:
  `Report.summary` returned its outer hash with an autovivifying default proc — unmarshalable.
  Fixed at the source (`default_proc = nil` before return). The null store had hidden it
  forever; the first real store found it in seconds.

## 4. The Requests N+1
`ProposedTerm.refresh!` was batched except `resurged` — one COUNT per resolved key (~300 on
HSDL, on every GET). Now one JOIN against the per-key verdict cutoffs; values identical
(the v0.9 reproposal pins are the proof).

## Honesty notes
- The preview is as-of-last-cycle and says so. Between cycles it can drift from reality; the
  beat re-plans at start, so nothing incorrect can execute — only the PREVIEW ages.
- Cached rollups can lag manual tends by up to the TTL; each heartbeat republishes via the key.
- A large fresh host (no ledger rows) still pays one live census on the Heartbeat page —
  ~2–3s post-§1 — until its first beat.
- Audit/considerer/conservator spend remains untracked by the token budget (unchanged).

## Done = all of:
- §1–4 + specs (PreparedPlan round trip; ledger-sourced previews pinned with
  `not_to receive(:plan)`; cache hit + heartbeat-key bust on a memory store; resurged values
  identical). **431 examples, 0 failures.**
- Measured on HSDL after restart: Status 18s → sub-second warm; Heartbeat 13s → instant;
  Requests 0.55s → ~0.1s. (Recorded below the commit.)
- SPEC, README, About colophon, CLAUDE.md.

# v0.21 — The Atlas (the enliterated collection, drawn)

AWS checked in on the Bedrock grant; HSDL staff are following; FEDLINK is five weeks out.
Jeremy wanted a shareable graph visualization (infoguana's force-directed look as the
reference) and named the framing question himself: Enliterator goes beyond "knowledge graph
as generally considered, but it can be expressed as one?" Yes — and the expression is the
argument:

- **The claim store IS a labeled property graph.** Records are nodes; a claim whose value
  names things (an advisor, an agency, a superseded order, a related report) is a typed edge.
- **The edge taxonomy is the controlled vocabulary** — the librarian's syndetic structure,
  visualized. The legend draws itself from the keys actually present.
- **Every edge carries provenance**: tier, confidence, asserted-at, and the audit verdict
  where one exists (hover a line: "asserted Jun 8 · cheap · conf 0.82 · audited: supported").
  A generic KG has edges; this one has edges that can answer for themselves.
- **The graph grows nightly.** Every edge is stamped with its claim's created_at; the time
  slider replays the collection learning — compounding attention made visible.

## 1. `Enliterator::Atlas` (host-generic builder — no per-host configuration)
- Claims in scope: live, engine-derived OR `human:*` (curator corrections) — the condition
  reconciler's locked flags ("condition-survey") and host seeds are NOT understanding.
  Context-scoped by the v0.13 cumulative read.
- A key is ENTITY-BEARING adaptively (median extracted term ≤ 90 chars) — prose keys fall
  out with no denylist. Extraction tolerates the shapes claims actually hold (string / array /
  array of {type:, designation:} hashes).
- **Resolution**: an index of unique IDENTIFIER claim values (keys named like control
  numbers — `eo_number`, `report_number`) plus record titles. `supersedes: ["13129"]` finds
  the record whose eo_number is "13129" → a directed record→record edge. Identifier claims
  self-resolve and draw nothing; attribute claims (advisor, cluster) never enter the index
  (the first cut indexed every short value and attribute claims self-resolved into SILENCE —
  caught by spec). Collisions drop out of the index: a string two records share can't name one.
- Unresolved strings become entity nodes deduped by exact normalized string — "DHS" and
  "Department of Homeland Security (DHS)" are two nodes until vocabulary governance merges
  them; the atlas makes authority-control work VISIBLE, and cited-but-untended works appear
  as small dots: the frontier.
- Context diamonds + membership edges give the layout its gravity wells. `atlas_node_cap`
  (default 1,500) keeps the most-connected and says so in meta.warnings. Cached with the
  v0.20 idiom (heartbeat-keyed + 5-min TTL).

## 2. The surface + the export
- `/enliterator/atlas` (nav: Atlas, after Contexts) + `/atlas/data` JSON. The page EMBEDS its
  data — the same `_viewer` partial renders live in the engine and standalone in the export.
- The viewer is ~300 lines of inline vanilla JS on `<canvas>` (hard rule 2: no D3, no CDN):
  grid-bucketed repulsion + springs + hub gravity, settles and freezes; zoom/pan/drag; node
  and EDGE hover tooltips (the provenance line); click-through to the status drill-down
  (live mode only); legend toggles per group; search-highlight; the time slider + replay.
- `rake enliterator:atlas` (FILE= CONTEXT= TITLE=) → ONE self-contained HTML file — opens in
  any browser, no server: the emailable artifact for AWS/HSDL staff, footer-stamped with its
  preparation date (finding-aid honesty).

## Honesty notes
- Entity identity is exact-string; merging is vocabulary governance's job, not the renderer's.
- Identifier keys are recognized by NAME PATTERN (number/id/code/doi/isbn/issn) — a host with
  eccentric identifier names gets entity nodes instead of resolved edges (degraded, never wrong).
- The export is a snapshot (assembled fresh, not cached) and says when it was prepared.
- The graph draws TENDED understanding only — 511 of HSDL's 315K records today. The sparse
  atlas IS the honest picture; the heartbeat fills it in nightly.

## Done = all of:
- Builder + surface + export + 17 new examples; **448 green**.
- Live on HSDL: EO supersession renders directed; advisor/agency/cluster hubs form; the
  replay shows four days of learning; election-security scopes to its neighborhood.
- README (nine surfaces), About colophon, CLAUDE.md.

# v0.22 — Portability (the enliteration is a movable asset)

Jeremy, looking at staging: "What happens when HSDL is pushed to staging and prod? Can we add
a /maintenance_task to copy over dev enliteration data — no use wasting inference." Right on
both counts. Everything the engine has learned — claims with their provenance chains, the
RATIFIED vocabulary (irreplaceable curation), audits, embeddings (real spend) — lives in
enliterator_* tables that a fresh deployment creates EMPTY. Re-deriving it re-buys the
inference and loses nothing-but-money; the understanding itself is portable.

## 1. `Enliterator::Portability`
- **export(path, measures: false)** → ONE tar archive (stdlib Gem::Package — no new
  dependency): `manifest.json` (per-table row counts + COLUMN LISTS, generated_at, host) +
  one gzipped **PostgreSQL binary COPY** stream per table (binary COPY round-trips
  vector/jsonb exactly; streamed via raw_connection.copy_data — no shelling to pg_dump).
- **import(path, force: false)** — refuses a non-empty target by name (`force` = ONE
  multi-table TRUNCATE, never CASCADE: cascading outside engine tables must be impossible);
  loads in FK-safe order with **ids preserved verbatim** — every supersession chain, every
  visit→heartbeat link survives — then resets sequences so the target's next cycle numbers
  AFTER the imported history. `import_table` is the per-table entry point (built for a host
  maintenance-task UI to show per-table progress).
- **The compatibility guard is the column list**: COPY carries an EXPLICIT column list on both
  sides (the dry run on real data caught that a migration-built database and a schema.rb-built
  one order columns differently — bare binary COPY would have loaded same-typed columns
  crosswise), so physical order is free to differ; a missing/extra column aborts by name — a
  version-skewed archive must never load crooked data.
- **The condition register stays home by design** (excluded unless measures:): it is free to
  re-derive (no LLM) and must describe the TARGET's files — a record's url_status on prod is
  not its url_status on dev. Import says so and points at `enliterator:survey`.
- Rake: `enliterator:export FILE= [MEASURES=1]`, `enliterator:import FILE= [FORCE=1]`.

## 2. The deploy checklist this version surfaced (HSDL → staging/prod)
1. **Push the engine first** — HSDL's initializer sets v0.18+ config (heartbeat_audit_sample);
   a deploy bundling v0.17 from GitHub crashes at boot. Engine migrations also load from the
   gem's paths (none are copied into the host), so table availability tracks the bundled
   version.
2. Wrap `/enliterator` (and confirm `/maintenance_tasks`) in the host's auth.
3. Server env: ENLITERATOR_LLM_KEY.
4. The pacemaker is per-host adoption (launchd on the Mac; cron/systemd timer elsewhere).
5. Seed the data: export on dev → scp → import on the target (the HSDL side wraps this in
   `Maintenance::ImportEnliterationTask` for the /maintenance_tasks UI).

## Honesty notes
- Claims for records that exist only on the source become ORPHANS on the target — inert (the
  planner skips missing records; the atlas labels them by id). A PRUNE option is deferred.
- The first heartbeat after import may carry a source_change wave (the target's updated_at vs
  the imported visit anchors) — honest, budget-capped: the target's files may genuinely differ.
- Binary COPY ties archives to compatible schema versions — the manifest enforces, by name.
- measures excluded by default is a CORRECTNESS position, not a size optimization (though it
  is also 535MB of HSDL's 600MB).

## Done = all of:
- Service + rake + 6 round-trip/guard examples; **454 green**.
- Real-data dry run on HSDL dev: export (~claims/visits/vocabulary/embeddings), import into a
  scratch database built from schema.rb, counts verified.
- HSDL: Maintenance::ImportEnliterationTask on the gated branch.
- SPEC, README (the checklist), CLAUDE.md, About colophon.

# v0.23 — Every Cycle Ends on the Ledger (failure states, managed)

The patient: cycle #12 (a Beat-now), orphaned by a server restart. The old process drained
gracefully — its thread kept tending for minutes, stamped the considerer and conservator
summaries, then died MID-AUDIT. The row read "running" forever; the monitor said "running
considerer…" with no stall path once items hit 56/56; the ticker showed Central-clock times
two hours off the header. Jeremy: "here's a good moment to ensure failure states are managed
correctly." No Ruby rescue catches SIGTERM — the ledger needed a different discipline.

## 1. The row always knows where it is (`pulse_at` + `phase`)
`pulse!(name)` — one `update_columns` — fires at every phase boundary AND inside every LLM
loop (per item, per scope, per claim, per survey batch). Liveness exists in phases that
produce no visits, which is exactly where #12 died invisible.

## 2. The reaper (`Heartbeat.reap_orphans!`)
Unfinished + no sign of life for REAP_AFTER (15 min; generous against one quality call under
the new gateway timeout) → stamped: `finished_at` = the last sign of life, the death phase
named in `error`, and **`executed` RECONSTRUCTED from the visit record** — the ledger heals
from its own provenance. `COALESCE(pulse_at, updated_at, started_at)` covers pre-v0.23 rows.
Runs FIRST in `open!` (a dead row no longer blocks the next beat for the rest of the 6h
window) and on the monitor page (the UI heals on view).

## 3. The zombie stands down
Today's exact case: a draining old process whose thread keeps spending after its row is
declared dead. Every loop iteration checks `pick(:error)` (one indexed read per LLM call) and
raises `StoodDown` — caught above the generic rescue so the reaper's stamp is never
overwritten. The phase rescues that warn-and-continue (survey, audit) re-raise it explicitly.

## 4. The monitor tells the truth
The stall check now comes FIRST and keys off `pulse_at` — it fires in every phase, including
at items 100% (the gap that hid #12). The label names the actual phase ("running audit…").
Ticker rows render `at_label` — app-zone times from the server — so the header and the ticker
finally agree (the browser's system zone is Central; the app's is Pacific — the launchd clock
gotcha had reached the UI).

## 5. Bounded gateway calls
`gateway_timeout` (180s) + `gateway_max_retries` (1) passed to both OpenAI clients (LLM +
embedder). The gem's defaults — 600s × retries — let one wedged call stall a phase for tens
of minutes with no sign of life. A deliberate default change, both knobs configurable.

## Honesty notes
- The reaper can end a WEDGED-BUT-ALIVE cycle; stand-down stops further spend at the next
  loop check, but tokens already in flight are spent. Named, accepted.
- REAP_AFTER is a constant (15 min). A host whose single calls legitimately exceed it would
  reap live cycles — derive from gateway_timeout if that host ever exists.
- Reconstructed `executed` counts only what VISITS prove; skipped items (no visit row) are
  not recoverable post-hoc and aren't invented.
- Pre-v0.23 rows reap via updated_at = their last phase stamp — coarser than a pulse, honest
  about it ("unknown (pre-v0.23 row)" when phase was never stamped).

## Done = all of:
- Migration (pulse_at, phase) on dummy + HSDL; pulse!/reaper/stand-down/monitor/timeouts;
  9 new examples. **463 green.**
- The patient healed: cycle #12 reaped on the live HSDL page — executed reconstructed from
  its 61 visits, death phase named, monitor freed; its considerer's 18 approve-recommendations
  were already waiting on /requests.
- SPEC, README, CLAUDE.md, About colophon.

# v0.24 — The Catalog (browse the enliterated holdings)

Every surface so far was curatorial back-office or a single keyhole — Chat retrieves five
records, /status/:type/:id shows one. Jeremy: "I do see the need to browse the enliterated
collection in a useful and interesting and educating way." Library science already has the
piece: the CATALOG — the OPAC over the holdings. Search by meaning, browse by subject
heading, and on every card the UNDERSTANDING, not just the metadata: accumulated claims,
tending depth, contexts, last visit. The educating part is the cards — the compounding,
visible at the shelf.

## 1. Two spines, deliberately
- The GRID and SEARCH walk the embedding spine (`kind: "primary"` — one row per enliterated
  record, the exact pool Conversation retrieves from, now shared as `Embedding.in_context`).
  Browse counts and search reach agree with Chat by construction.
- SUBJECT browse walks the claim store: live UNDERSTANDING claims (`Claim.understanding`,
  extracted from the Atlas), read cumulatively up the context path AND intersected with
  membership — without that, a non-member's root claim would leak into a scoped browse.

## 2. Headings congruent with their click-throughs (the load-bearing rule)
A heading is a byte-exact stored value. The filter is jsonb containment
(`value @> to_jsonb(term)`), which matches a scalar string and a string array element and
nothing else — so heading extraction admits exactly those shapes (no hash digging, no
numbers, no stripping). Counts are DISTINCT RECORDS (the same key/value at root and in a
context is one record). Identifier keys are excluded by NAME (Atlas::IDENTIFIER_KEY_RX —
control numbers are access points, not subject headings); a key with more values than the
display cap and no value grouping two records is identifier-shaped and skipped. Spec-pinned:
every offered heading's count equals its click-through total.

## 3. Honest at corpus scale (the v0.20 law applied)
The landing blob (stats, headings, recent, per-type counts) is cached 5 min keyed to the
latest heartbeat id. The grid orders by ACCESSION (newest embeddings first — index-backed,
stable; ordering 330K records by last-visit would be a per-view census). Heading tallies cap
at 50,000 scanned claims per key and render "≥" beyond. ANN search returns one honest page
(the K nearest), no pager. Pages clamp into range; a page the collection moved out from
under says so. The new `[key, context_id]` claims index serves the heading/subject/sampling
queries (nothing led on `key` before — Synopsis.key_summary rides it too).

## 4. Degraded search names itself
The Null embedder's deterministic pseudo-vector would RANK against real embeddings and look
like results — so search degrades by name ("null-embedder" when unconfigured outside specs,
"no-vector" when the gateway returns nothing) and the page falls back to the browse with the
reason stated. No fake results, ever.

## 5. Wander
`/catalog/wander` lands on one random record's full entry — the serendipity of open stacks,
one OFFSET query.

## Honesty notes
- The grid shows EMBEDDED records (the spine); subject browse covers all claim-bearing
  records. They can differ by records that hold understanding claims but were never embedded
  — rare by construction (the visitor embeds before tending), named here.
- Headings are claims-in-use, not authority records: no syndetic structure, no see-also.
  (SKOS export is the future shape for that.)
- Hash-shaped and numeric claim values never become headings — not a modeling judgment, a
  FILTERABILITY rule: a heading the filter can't find again is a lie.
- Search requires the embedder; there is no keyword/full-text fallback index (deliberate —
  the catalog's search IS the literacy thesis; ILIKE over jsonb at scale is a trap).
- Card claim counts are UNDERSTANDING claims; /status/:type/:id additionally shows condition
  flags and host seeds, so its claim table can read higher. Same records, wider ledger.

## Done = all of:
- Migration ([key, context_id]) on dummy + HSDL; Catalog service + controller/views;
  `Embedding.in_context` + `Claim.understanding` extracted (Conversation/Atlas refactored,
  their suites the regression net); 25 new examples. **489 green.**
- Live on HSDL dev: stats over the real corpus, real headings with congruent counts,
  semantic search, context scoping, wander.
- SPEC, README (ten surfaces), CLAUDE.md, About colophon.

# v0.25 — Analytical Cataloging (the deep read, piloted)

Tending read ~6K chars of front matter; a median converted thesis is 220K. Jeremy: "Say some
collections, like the CHDS theses, warranted deeper understanding... How can we really use
the model's capacity to read the whole thing? A librarian per-record?" Library science has
the piece: ANALYTICAL ENTRIES — describing the PARTS of dense works, which libraries always
wanted and could never afford. The economics just flipped.

## 1. Parts: sections as first-class tendables
`Enliterator::Part` (record polymorphic, ordinal, heading, stored text slice, content
digest) includes Tendable — visits, claims, reconciliation, escalation, suggestions, audit
grounding, embeddings, trajectories all work polymorphically, zero special cases. The host
contract is `to_enliterator_parts` → [{heading:, text:}] (mirrors to_enliterator_text);
`Part.refresh_for!` reconciles rows by ORDINAL (content change updates in place — claims
survive, the clock moves; vanished trailing sections destroy, notes cascade).

## 2. Engine-internal, by rule
Parts get the machinery but never the registry: `register_tendable` skips `Enliterator::*`
classes, and the "Registry ∪ visit log" authority rule (planner root lanes, Condition,
Settings, the Catalog corpus) reads `Visit.host_tendable_types`, which excludes engine
types by name — a TENDED part must not be resurrected into root lanes or the census.
Drill-down stays reachable: `Enliterator.tendable_type?` (status#show, catalog type filter)
admits registered hosts ∪ Part, so an analytical entry has an entry page.

## 3. The reading (`Tending::Reading`)
One librarian's session: section → read each part on the `analysis` facet (a plain Visitor
pass — vocabulary, required terms, escalation all apply) → file a `kind: "part"` embedding
per content version → re-tend the work-level facets from the NOTEBOOK
(`Part.notebook_for`: every part in order, each live analysis claim under its heading).
Skip-if-fresh per part (unchanged digest + a succeeded read = the v0.14 NOOP-spend verdict
applied inside the document). Three straight failed reads with nothing tended = stand down
(the heartbeat's misconfiguration rule). The host's `to_enliterator_text` decides synthesis
input: HSDL returns the notebook for summary/significance/connections once notes exist —
so the deepening SUPERSEDES the front-matter understanding in place, "Understanding over
time" shows it, and Trajectory::Judge can compare it blind.

## 4. `scheduled: false` (the no-unsupervised-deep-reads pin)
The analysis facet must live in the policy (the Visitor resolves tier/vocabulary/required
from it), but policy context declarations FEED PLANNER LANES — without a gate, the next
pacemaker cycle would start deep-reading unsupervised. `facet ..., scheduled: false` keeps
a facet fully staffed but out of `schedulable_facets_declared_in`, which both lane builders
now use; `facets_declared_in` is untouched (manual tend_context still reaches it).

## 5. The pilot, before the campaign
HSDL: `to_enliterator_parts` sections docling markdown on h2 headings (merge < 1,500-char
fragments, hard-split > 30K, boilerplate dropped — nobody takes reading notes on the table
of contents); the `analysis` facet (8 terms, summary REQUIRED) at QUALITY tier (whole
sections need the window; cheap-tier economics are the campaign's question);
`evidence_base` added to significance (only answerable from a whole-work reading).
`enliterator:deep_read_pilot N=25` reads the cohort and puts each thesis's shallow vs deep
understanding in front of Trajectory::Judge — blind pairwise winner/richer/more_accurate.
The judge's verdict gates v0.26 (heartbeat lane integration) and the Bedrock batch campaign
(~$200–500 for all 1,327 theses — the grant's named workload).

## Honesty notes
- Synthesis claims are NOTEBOOK-grounded, not source-grounded; part claims are
  source-grounded against their own section. The provenance chain records exactly that, and
  the examiner verifies each against the same text its tend read (the part's slice; the
  notebook) — a derivation audit for synthesis, named plainly.
- Part text is a stored COPY (~300MB at full-corpus scale; ~5MB pilot) — chosen so
  content_digest is stable evidence independent of re-conversions.
- refresh_for! reconciles by ordinal: re-conversion that shifts sections re-reads them
  (digest change) and a vanished trailing section's notes are destroyed. Coarse, honest.
- The synthesis can NOOP — verified live on the first reading: the abstract-grounded
  summary was already faithful and the reconciler refused to churn it. The deepening showed
  where front matter couldn't reach (significance: 3 added + 3 updated, evidence_base
  minted). Ties on summary in the judge table are expected, not failure.
- Part embeddings (kind "part") accrue but no surface retrieves them yet.
- First engine-side embedding writer (the Reading); primaries remain host-mirrored.
- Found and fixed in the host while wiring: HSDL's `to_enliterator_text(stream:)` kwarg
  predated the v0.12 stream→facet rename, so the engine's facet-aware dispatch NEVER fired
  — the authorship title-page branch was dead and only worked because the generic 6K head
  contains the title page. Renamed to `facet:`; the branch is live for the first time.

## Done = all of:
- Migration (enliterator_parts) on dummy + HSDL; Part + Reading + scheduled gate +
  registration rules; 17 new examples. **506 green.**
- Verified live on HSDL: one thesis read whole (26 parts, 208 analytical claims, 124,718
  tokens, zero failures), real scholarly notes (cited_works naming Hoffman/Schmid/Gurr,
  index_terms as subject headings), significance deepened with supersession visible,
  pacemaker plan clean of analysis items, part entry page renders.
- The 25-thesis pilot run + judge verdict table (tmp/deep_read_pilot.md on HSDL).
- SPEC, README, CLAUDE.md, About colophon.

# v0.26 — MCP Tooling (the agent's reading-room card)

Jeremy: "What tools would empower you to intelligently conversationally navigate,
understand, and communicate an enliterated collection?" Designed by its consumer. What an
enliterated collection uniquely offers an agent is PROVENANCE, TRAJECTORY, and
SELF-KNOWLEDGE — calibration tools no RAG server has: the agent can say "authorship claims
here audit at 95% supported" and "the collection revised this after reading the whole
thesis" instead of hedging uniformly. Nearly every tool is a thin projection over a cached
service built in v0.6–v0.25; this version is the agent-shaped hands.

## 1. The endpoint: the protocol minimum, inline
`POST /enliterator/mcp` — JSON-RPC 2.0, Streamable HTTP, tools only. initialize /
notifications (202 empty) / tools/list / tools/call; POST-only, always application/json
(no SSE — clients accept plain JSON); GET 405; stateless. ~120 lines, no gem — the "UI is
100% self-contained" ethos extended to the agent surface. Protocol misses are JSON-RPC
errors (-32601/-32602/-32700); tool failures are isError results with ACTIONABLE text,
never a backtrace. Wire-up: `claude mcp add --transport http enliterator
http://localhost:3055/enliterator/mcp`.

## 2. Thirteen tools (11 read, 2 governed-write)
Orient: collection_overview (the self-portrait: stats/contexts/facets/condition/accuracy),
vocabulary (the claim language). Navigate: search (Chat's pool — counts agree everywhere),
browse_subjects + subject_search (the v0.24 congruence, agent-shaped), record_entry (THE
core tool: claims grouped by facet, each with provenance on its sleeve — confidence, tier,
status, locked, attribution, latest audit verdict — plus tending rollup and analytical
entries when deep-read; a Part has an entry too). Connect: connections (typed edges from
the CACHED atlas + semantic neighbors). Calibrate: trajectory (how understanding
compounded, visit by visit), provenance ("how do you know that?" — the full chain),
quote (claim → primary material: the passage located lexically in the same text the tend
read), accuracy (the audited rates, said out loud). Participate: propose_term (a pending
suggestion riding pressure→considerer→curator), flag_claim (an agent audit reaching the
review queue).

## 3. The agent is eyes, never a hand (the scoping rule)
Audit::SOURCES gains "agent", and the v0.18 instrument scopes to `instrument`
(examiner + human) in all four aggregation sites: effective_verdicts, audit_pairs, the
sampler's never-examined pool, and the Atlas verdict precedence. SPEC-PINNED: an agent
flag changes NO accuracy number and does not remove a claim from the examiner's sampling
pool — its whole purpose is to reach a human, so agent flags enter the /review queue
beside examiner verdicts (confirm/overrule/correct work identically; the chip names the
source).

## 4. Bounded and self-describing, by discipline
The agent's context window is a budget exactly like the heartbeat's: every collection
capped (search 10, claims 60, edges 40, neighbors 8, parts 80), every long value truncated
with a flag, quote windows ≤1,200 chars. Every response carries `next:` hints naming the
follow-up tools and the /enliterator path a human would use — the asymmetric-observability
counter-pattern, applied to the agent as consumer.

## Honesty notes
- The protocol MINIMUM, deliberately: no SSE, resources, prompts, sampling, or sessions.
- Auth posture is the mount's (auth-less dev; the staging wrap covers /enliterator/mcp —
  same prefix). No Origin validation yet — named as a hardening item before any
  non-localhost exposure.
- quote's span location is LEXICAL (exact match → densest token cluster → head-of-source
  with located: false). It never fakes a quote; it says when it couldn't find one.
- search requires the embedder and SAYS SO when degraded (the error names
  browse_subjects/subject_search as the working alternatives).
- record_entry's verdict display ranks human > examiner > agent — an agent flag shows but
  never outranks the instrument.

## Done = all of:
- Endpoint + 13 tools + audit scoping; 21 new examples (7 protocol + 14 tool). **527 green.**
- Live on HSDL dev: the JSON-RPC handshake by curl, real tool calls over the deep-read
  thesis (record_entry with parts, trajectory showing the deepening, provenance + quote on
  an analytical claim), the governed writes landing on /requests and /review.
- SPEC, README, CLAUDE.md, About colophon.

## v0.26.1 — analytical entries roll up in the Atlas
Found live the same day: the deep-read pilot's 940 parts (8K part claims) flooded the
atlas node cap with part nodes that carry no context membership — no gravity well — and
the layout exploded. The rule, now spec-pinned: THE ATLAS DRAWS WORKS. A part's claims
(cited_works, index_terms) contribute their edges to the parent record's node and resolve
identifiers to the parent; part nodes never exist. The deep read's payoff lands where it
belongs: the citation graph drawn from the works themselves (132 cited_works + 1,760
index_terms edges on HSDL the day the pilot finished).

# v0.27 — The Brief (the collection reports its own night)

## Why
"How did last night's tending go?" was answered by hand-composing the same query every
morning: heartbeats, visits, failures, readings, governance — re-derived each time,
forgetting the same corners. The records were always there (the ledger, the immutable
Visit history with errors on the failures, the governance tables); nothing composed them.
The Brief is that composition written once — compounding tooling for operating the
engine, in the engine.

## What
`Enliterator::Brief.report(since:)` — a pure-read, time-windowed digest (default 12h;
a Duration reads as "ago"):
- **headline** — one relayable line: cycles, visits (failed count), deep-read visits, tokens.
- **heartbeats** — each ledger row compacted: planned, executed rollup by status, tokens,
  warnings, error.
- **visits** — total, by facet×status, by tier, by reason, token sum (ONE pluck feeds
  headline + rollup + readings; the Visit table is the busiest in the engine).
- **failures** — count + sample (cap 10, flagged truncated) WITH each visit's recorded
  error (rule 3 pays off: no log-grepping).
- **readings** — deep-read part visits rolled up to their parent records (sessions, not
  page turns): records, parts read/failed, syntheses, tokens.
- **governance** — suggestions filed (by status), proposed-term motion (by
  recommended_decision; updated_at reads as "moved" — the table mutates in place),
  audits by source×verdict.
- **embeddings** — rows written in the window.

Surfaces (thin projections, the v0.26 law):
- `rake enliterator:brief` (`HOURS=` default 12) — the terminal morning read.
- MCP tool **`recent_activity`** (`hours` 1–168, clamped not errored) — the 14th tool;
  where collection_overview is the self-portrait (state), recent_activity is the diary
  (change). Carries `next:` hints like every tool.

## Honesty notes
- The Brief is BREADTH over a window; `Report.summary` stays the DEPTH instrument
  (adapter mix, escalation/empty-final rates, confidence). The Brief deliberately
  duplicates none of it — read the Brief first, reach for `enliterator:status` when a
  number looks wrong.
- Pure read: no network, no cache writes, no migration. Byte-identical when unused.
- ProposedTerm has no status column — motion is grouped by `recommended_decision`
  (nil reads as "open").

## Done = all of:
- Service + rake + MCP tool; 8 new examples (7 service + 1 tool) + the tools/list pin
  moves 13→14. **537 green.**
- Live on HSDL dev: `bin/rails enliterator:brief` reproduces the night the tool was born
  from (the Bedrock sample's failures with their gateway errors, the 1:30 AM heartbeat,
  the deep-read rollup).
- SPEC, README, CLAUDE.md, About colophon.

# v0.28 — The Reference Desk (the agentic core)

## Why
The authed `/enliterator/chat` could answer a question. It couldn't hold a conversation
across tools — triage it, hand it to the right expert, show its provenance inline, recover
visibly when a tool failed. A reference interview is not a single shot; it's a governed
exchange where the desk knows what it can answer, knows when to say "let me connect you
with a specialist," and never pretends confidence it doesn't have. v0.28 builds that desk
into the engine — agentic, federated, gated.

## What

### Gateway primitive: `Gateway#converse_with_tools`
A NEW adapter method — optional-multi-tool: the model chooses whether and which tools to
call. Returns a `ToolTurn` (text OR tool_calls with ids + the assistant message to feed
back into the loop). Streams text deltas. Only the Gateway adapter implements it; Null and
Bedrock inherit a `NotImplementedError` — a misconfigured federation fails loudly rather
than silently degrading.

### `Chat::Widget` — inline provenance for tool results
Pure functions `(tool_name, result) → self-contained HTML`, one renderer per
widget-worthy MCP tool (record_entry, provenance, trajectory, accuracy, search,
subject_search, quote, connections) + an unknown-tool JSON fallback. All untrusted tool
data is HTML-escaped; class-names only (the layout owns CSS — hard rule 2). Built to
later wrap as MCP Apps `ui://` resources (Plan B horizon).

### `Chat::Agent` + the federation registry
A federation of agents: a **Frontdesk** (nil grounding — triages + routes) and grounded
specialists (e.g. CHDS Theses, scoped to their context). Registration FAIL-FASTS if the
agent's tier doesn't resolve to a `converse_with_tools`-capable Gateway adapter — the
direct-Bedrock trap is caught at boot, not at first message. The registry guards a
duplicate Frontdesk. `Chat.for_context(key)` resolves the active agent, falling back to
the Frontdesk.

### `Chat::Loop` — the governed agentic loop
The **security enforcement boundary** (the loop, not the model, enforces):
1. **`route_to` intercepted FIRST** — a handoff instruction switches agent, emits a
   visible handoff event, and is NEVER dispatched as a tool call.
2. **Allow-list checked BEFORE `Mcp.dispatch`** — read-only enforcement. An injected
   web instruction can't call a write tool by name; the allow-list is the gate.
3. **Grounding injected only for context-bearing tools the model left unscoped** — a
   model-supplied scope is honored ("grounded, not walled").

On handoff the loop re-resolves the LLM per the new agent's tier and switches the system
prompt ("fast triage → capable advising" actually activates). Bounded by a step cap AND
a per-turn wall-clock budget. A tool failure or a mid-loop gateway raise becomes a
VISIBLE terminal event (rule 3), never a silent hang.

### Cached `Audit.accuracy`
The hot first-turn path (`collection_overview` runs it inline) now caches, keyed on the
audit set's last write + count — NOT a heartbeat id, because audits are filed out-of-band
between beats.

### Federation-gated transport
`ConversationController#stream` drives the agentic loop when `config.chat_federation` is
on, emitting the existing lowercase events `token` / `provenance` / `done` plus four new
events: `tool_call_start` / `tool_call_result` / `tool_call_error` / `handoff`. Event
vocabulary borrows AG-UI's semantics, not its casing. The off-path (federation OFF) view
is **byte-identical** — verified by literal diff; the widget-aware JS and scope-banner id
are ONLY inside the server-rendered federation gate.

## Honesty notes
- `config.chat_federation` is **OFF by default**. When unused the full suite is
  byte-identical to v0.27: no new behavior, no new risk surface. This is the project's
  core discipline applied to the agentic surface.
- The agentic chat is the **Plan A** of two. **Plan B** — the public accountless desk
  (sessionless controller, link token, rate limit, per-surface affordance scrub, the
  leashed web tool) — is the named horizon, not yet built. Full design:
  `docs/designs/2026-06-12-reference-desk-design.md`; plan:
  `docs/superpowers/plans/2026-06-12-reference-desk-agentic-core.md`.
- Null and Bedrock adapters raise `NotImplementedError` on `converse_with_tools` by
  design — federation with an incapable tier surfaces immediately.
- Widget HTML is class-name-only (no inline style); all untrusted tool data passes
  through html_safe only after `ERB::Util.html_escape`.

## Done = all of:
- `Gateway#converse_with_tools` + `ToolTurn`; `Chat::Widget` (8 renderers + fallback);
  `Chat::Agent` + registry (`Chat.for_context`, `Chat.register`, duplicate-Frontdesk guard,
  tier-validation fail-fast); `Chat::Loop` (route_to-first, allow-list-before-dispatch,
  context-bearing-only grounding, step cap, wall-clock budget, visible terminal events);
  `Audit.accuracy` cache (last-write + count key); federation-gated `ConversationController#stream`
  (5 new SSE event types, byte-identical off-path). **572 green.**
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.29 — The Reference Desk, Made Legible (the agentic surface, elevated)

## Why
v0.28 built the reference desk into the engine — agentic, federated, gated — but the
patron couldn't *see* it work. A turn was a single bubble; tool calls were invisible or
dumped as raw JSON; a handoff to a specialist passed silently; the prose claimed sources
it never linked. The desk was governed but illegible. And the surrounding pages, while
honest, read as a developer's scaffold rather than a reading room. v0.29 makes the
agentic exchange *readable as a reference interview* — a live work-trace, structured tool
widgets, a visible handoff, inline provenance you can click — and lifts the whole engine
into a scholarly visual register. No new behavior on the wire; the same governed loop,
finally shown.

## What

### Global design language (the reading-room register)
`app/views/layouts/enliterator/application.html.erb` (the one quiet component system,
v0.19) gains a scholarly type and depth vocabulary, applied engine-wide:
- A **system-serif display face** (`--font-display`) for `h1`, `h2`, and `.section-head`
  only — body copy stays the system sans. A refined scale (`--fs-display`) gives the
  headings a librarian's gravity without a single web-font byte (hard rule 1).
- Restrained depth tokens (`--shadow`, `--shadow-pop`) and an `--accent-dark` token for a
  consistent hover/active treatment; focus rings unified; all motion guarded by
  `prefers-reduced-motion`.
- The About page's stat-strip is promoted to a **shared component** (`.stats-strip` et al)
  so Status / Catalog / Atlas / About / Chat report counts in one congruent dialect.

This rippled to every surface — a coherence pass, not a chat-only change.

### `enl-*` widget CSS system (the tool-widget chassis)
Same layout file. The v0.28 tool widgets rendered self-contained HTML but the layout owned
no CSS for them — they were unstyled. v0.29 adds a fully namespaced component system: a
card chassis (`.enl-widget`) plus eight structured variants (overview, headings, vocab,
activity, results, provenance, trajectory, quote/edges), the working-trace timeline
(`.enl-trace*`: dot → spinner → ✓), the handoff divider (`.enl-handoff`), and the citation
furniture (`.enl-cite` chip + `.enl-cite__pop` popover + `.enl-sources` rail). Every
selector is `enl-`-namespaced, so on a federation-OFF page — which emits no `enl-*` DOM —
the rules select **nothing**. The CSS is inert, not absent; the *markup* is what the gate
withholds.

### Four new widget renderers
`app/services/enliterator/chat/widget.rb` gains renderers for the four tools that v0.28
left as raw-JSON dumps: `collection_overview` (a stat-strip dashboard), `browse_subjects`
(a subject-heading index), `vocabulary` (facet rows), and `recent_activity` (a diary).
Same discipline as v0.28: pure functions, class-names only, all tool data HTML-escaped.
The unknown-tool JSON fallback is collapsed into a `<details>` so an unrecognized tool is
inspectable but not loud.

### The agentic turn model (federation-gated)
`app/views/enliterator/conversation/index.html.erb`. When `config.chat_federation` is on, a
turn renders top-to-bottom as a narrative:
1. a **live work-trace** — one row per tool call, status animating spinner → ✓ (human
   labels, not method names), each tool's widget tucked into a `<details>` so the trace
   stays scannable;
2. the **answer**, created lazily on the first token so it lands *under* the trace;
3. a **sources rail** — the records consulted that turn, numbered, linking to the status
   browser.
The handoff is now a **visible divider** (`.enl-handoff`) plus a non-destructive update to
the scope banner (`#enl-scope-banner`) — the patron sees which desk is answering without
the page reflowing out from under them.

### Markdown extension (golden-guarded)
The shared client-side `mdToHtml` (used by BOTH the single-shot and federated paths) now
renders blockquotes, horizontal rules, GitHub pipe tables, and nested lists. Because it is
shared, extending it is the highest-regression-risk change in the upgrade — so it is frozen
by a golden-output test (`spec/javascript/md_golden.test.js`) that proves every
pre-existing markdown shape renders **byte-identical** after the extension, with negative
guards so the new matchers don't fire on look-alike input (a bare `--` is not an `<hr>`; a
pipe line without a delimiter row is not a table; HTML inside a quote or cell stays
escaped).

### Input + follow-ups (federation-gated)
Same view. The composer gains textarea autosize (`.enl-autosize` up to `.enl-ta-max`),
Enter-submits / Shift+Enter-newline, a typing indicator (`.enl-typing`) during the
~20s Bedrock turns, and **dynamic follow-up suggestions** derived from the records actually
consulted that turn (not a static list).

### Citations (federation-gated)
`widget.rb` emits per-record data attributes (type / id / label / entry path); the view
correlates them, client-side, from the streamed tool data. The result is two-fold:
- a **"Sources consulted" rail** under the answer — numbered, click-through to
  `/enliterator/status/<Type>/<id>`;
- **inline numbered citation chips** woven into the prose (a label match becomes a
  superscript `<button class="enl-cite">`; hover → a popover with the record's label +
  type, click → the record). The chip placement is text-node-only and never wraps text
  already inside a link — load-bearing safety properties frozen by
  `spec/javascript/cite_logic.test.js`.

### Grounding note (deployment-side, NOT an engine change)
The CHDS specialist's *prompt* (HSDL-side, in the host app) gained a **decisiveness
directive** so it composes after a focused set of retrievals rather than over-exploring.
This is grounding tuning at the deployment, not a change to the engine's loop or budget.

## Honesty notes
- **Citations are client-correlated, today.** The numbered chips and the sources rail are
  built in the browser by matching record labels emitted in the streamed tool data. The
  foundation is shipped; the *future* is a first-class structured `sources` SSE event plus
  a `DocMetum` → human-readable type-label map, so the server names the citation rather
  than the client inferring it. Deferred, named, not pretended.
- **The loop is unchanged.** No `tool_call_start` payload enrichment, no new SSE event
  type — the citation and trace data ride the existing v0.28 events. Enriching
  `tool_call_start` with structured record metadata (so the trace needn't re-derive it) is
  a future loop change, deliberately deferred to keep v0.29 a pure surface elevation.
- **Federation OFF emits no new DOM, JS, or CSS-bearing markup.** The trace, the widgets,
  the citation chips, the sources rail, the autosize/typing/follow-up behavior, and the
  federated JS (`handleFrameFederated`, `submitQuestionFederated`, `finishTurnFederated`,
  `annotateCites`, `makeCiteChip`, `buildCitePop`, `wrapFirstMatch`) are ALL inside the
  `config.chat_federation` server-rendered gate. The single-shot stream contract
  (`token` / `provenance` / `done`) is byte-identical to v0.27. This byte-identity is no
  longer only manually verified — a request spec
  (`spec/requests/enliterator/conversation_federation_spec.rb`) asserts the OFF-path body
  contains none of the `enl-*` agentic classes and none of the federated function names.
- **100% inline vanilla, still.** No CDN, npm, gem, asset-pipeline entry, or web-font was
  added. Serif headings use a system-serif stack; every widget, animation, and citation
  behavior is inline CSS/JS in the layout and the view (hard rule 1, held).
- No silent failures: a tool error still becomes a visible terminal step in the trace
  (rule 3), and the markdown/citation extensions degrade to plain rendering rather than
  throwing.

## Done = all of:
- Global design language (`--font-display` serif headings on h1/h2/.section-head, `--fs-display`,
  `--shadow`/`--shadow-pop`, `--accent-dark`, unified focus/hover, `prefers-reduced-motion`,
  shared `.stats-strip`); the `enl-*` widget/trace/handoff/citation CSS system (namespaced,
  inert on the OFF page); four new widget renderers (`collection_overview` / `browse_subjects` /
  `vocabulary` / `recent_activity`) + JSON-fallback collapsed into `<details>`; the agentic
  turn model (live trace → answer → sources rail, visible handoff + non-destructive scope
  banner); `mdToHtml` extension (blockquotes, rules, GitHub tables, nested lists) frozen by
  `md_golden.test.js`; composer autosize + Enter-submits + typing indicator + dynamic
  follow-ups; client-correlated citations (sources rail + inline chips) frozen by
  `cite_logic.test.js`. Federation OFF byte-identical — codified by an off-view regression
  spec. **All hard constraints held: inline vanilla only; single-shot contract unchanged;
  no silent failures.**
- SPEC, README, CLAUDE.md, About colophon.

# v0.30 — Actionable Errors at the Desk (the failure, made legible)

## Why
When a chat turn failed, the patron saw "conversation failed" and nothing else — and so
did the developer who built the deployment. The actionable part of the failure — *which*
tier, *which* exception, *what to do about it* — was constructed nowhere and dropped on the
floor. The most common real failure in dev is an expired AWS SSO session: a 20-second wait
that ends in a blank red bubble, with the fix (`aws sso login`) living only in the
operator's head. v0.30 makes the desk **tell you what broke and what to do** — but only
where it is safe to: in development by default, optionally in other envs, **never in
production**. The reusable pattern is the deliverable; the chat surface is its first (and,
this version, only) consumer.

## What

### `config.error_detail` — the gate, three-state (`lib/enliterator.rb`)
A single config knob governs whether actionable detail is ever assembled: `nil` (the
default) = **auto**, `true` = always, `false` = never. The resolver `error_detail?` reads
it through, never directly; when `nil` it consults `error_detail_auto`, a callable that
defaults to the dev-env guard (`defined?(Rails) && Rails.respond_to?(:env) &&
Rails.env.development?`). This is the **one guarded `Rails.env` touch** in the engine —
mirroring `logger` — and like `logger` it is host-overridable: a strictly env-policy-free
host replaces the predicate via `error_detail_auto=`. "Actionable errors in dev by default,
optionally other envs, off in prod" — expressed as one resolver, not scattered conditionals.

### `Enliterator::Chat::ErrorReport` — the sole constructor (`app/services/enliterator/chat/error_report.rb`)
The single place the chat `:error` payload is built. `build(error, where:, detail:, message:)`
returns `{message:}` **always** — and `message` is the caller's static literal (e.g.
`"conversation failed"`), never `error.message`, so a secret in the exception can never route
itself around the gate. When `detail` is true it adds three keys: `detail:` (`"Class:
message"`), `where:` (engine-internal labels humanized to a compact string — stage · agent ·
tier · tool), and `hint:` from an ordered, first-match-wins `HINTS` table. The gate is one
line — `return h unless detail` — and it is the whole security argument: nothing may be added
past it, pinned by a keys-canary spec that asserts the OFF payload has exactly one key. Unlike
`Widget`, `ErrorReport` renders **no HTML** (the client escapes via `textContent`), so there
is no `h()` here.

The `HINTS` table is advisory triage, matched against `"#{error.class}: #{error.message}"` so
a bare error still resolves on its class name: AWS SSO expired → "re-run `aws sso login`";
gateway timeout; tier-alias not advertised; gateway unreachable; key rejected;
`NotImplementedError`/`ConfigurationError` (a tier that can't `converse_with_tools`). Patterns
are narrow and most-specific-first; an unmatched error gets **no hint key** — the class and
message still show.

### Loop + controller emit a structured `:error` (gated, server-resolved)
The model-call failure in `Chat::Loop` is now an `:error` event (not a degenerate `:token`),
routed through `ErrorReport`; a tool failure carries detail/hint when detail is on. The
`ConversationController`'s outer stream rescue is likewise routed through `ErrorReport`, so it
covers **both** the federated and the single-shot path. `error_detail` is resolved
**server-side only** — `error_detail?` is read in the controller, never from a request
param — so a client cannot turn detail on by adding `?error_detail=1`. Pinned by a request
spec that asserts no query param enables it.

### The client error card (`renderErrorCard`, textContent-safe, federation-gated)
A distinct `.enl-error` card replaces the bare red bubble: the generic `message` always; when
`detail`/`where`/`hint` are present (dev), the class+message, the "where" line, and the hint.
Every field is written with `textContent`, never `innerHTML` — the payload is HTML-unaware by
construction (`ErrorReport` emits none), so the card is XSS-safe. The renderer is converged
across all three error paths: the `:error` SSE event, the transport `.catch`, and
`tool_call_error`. An `els.errored` flag stops the turn-finish flush from erasing the card —
the failure stays on screen instead of being cleared by the normal end-of-turn cleanup.

## Honesty notes
- **Detail is dev-default, config-gated, and never reaches production.** With `error_detail`
  left `nil` (the default) the auto predicate is true only in `Rails.env.development?`; in
  prod the payload is byte-identical to today's `{message: "conversation failed"}`. A host
  that wants detail in staging sets `config.error_detail = true` deliberately; a host that
  wants it never sets `false`. The gate is the security boundary, spec-pinned.
- **The hint map is advisory, not authoritative.** It is a first-match-wins table of narrow
  patterns; an unmatched error simply gets no hint — the class and message are still shown, so
  the developer is never *worse* off than a raw exception. The hints encode this deployment's
  known failure modes (gateway, Bedrock SSO, tier aliases); they are guidance, not diagnosis.
- **The pattern is reusable; only the chat path is wired.** `ErrorReport` + `error_detail?` are
  surface-agnostic — any future streaming or AJAX surface can adopt the same gated card. This
  version wires only the chat `:error` path. Global non-chat error surfacing (other engine
  pages still use Rails' own dev error page), a backtrace in the card, and the public
  accountless desk consuming this with `detail:false` are **out of scope, named not pretended**.
- **No silent failures, no new wire risk.** A failed turn becomes a *visible* card (rule 3),
  not a swallowed exception. Federation OFF and the OFF-view are unaffected — the card is
  emitted through the same gated transport, and the prod/off payload is unchanged byte-for-byte.
  Live-proven: a real expired-AWS-SSO model error now surfaces the class+message,
  "model call · Frontdesk · bedrock-haiku", and the "re-run `aws sso login`" hint.

## Done = all of:
- `config.error_detail` (3-state nil/true/false, default nil) + `error_detail?` resolver
  (the one guarded `Rails.env.development?` touch, host-overridable via `error_detail_auto=`);
  `Enliterator::Chat::ErrorReport.build` as the sole `:error` constructor (`{message:}` always
  from a static literal; `detail`/`where`/`hint` added only past the `return h unless detail`
  gate; ordered first-match-wins `HINTS`; keys-canary spec); `Chat::Loop` + `ConversationController`
  emit a structured `:error` through `ErrorReport` (model + tool + outer stream rescue, covering
  federated and single-shot), `error_detail` resolved server-side only (no-query-param request
  spec); client `renderErrorCard` (textContent-safe `.enl-error` card, converged across `:error`
  / transport `.catch` / `tool_call_error`, `els.errored` survives the turn-finish flush).
  **Prod/off payload byte-identical to v0.29; federation-off and the OFF-view unaffected; no
  silent failures.**
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.31 — The Reading Room Quiets (chat chrome recedes; the thinking timer)

## Why
The conversation surface opened loud — a header, an explainer, a scope banner all competing
with the empty composer — and once a turn was running, the patron stared at an empty trace
box with no sign the desk was working (the agentic turn's first tool call can be ten silent
seconds). v0.31 makes the room behave like a reading room: it greets you when empty, recedes
once you're talking, and shows the desk thinking. Pure surface; the loop is untouched.

## What

### A welcoming empty state, receding chrome
Federation-gated. With no turns yet, `/chat` leads with a calm empty state; on the first
question the surrounding chrome recedes so the exchange owns the page. Nothing the off-view
contained is removed from the DOM — the recede is a class toggle on the federated surface
only.

### The live "Working… Ns" thinking timer
While the desk works a turn, an unobtrusive indicator counts the elapsed seconds, so a
ten-second first-tool latency reads as *working*, not *hung*. And an empty work-trace — a
turn that calls no tools — no longer renders an empty "view" affordance; the trace box
appears only when there is a trace to show.

## Honesty notes
- Federation OFF / the single-shot view are byte-identical: the empty-state, the recede, the
  timer, and the empty-trace suppression are all inside the `config.chat_federation` gate.
- No new SSE event, no loop change — the timer is client-side wall-clock; the recede is CSS.

## Done = all of:
- The welcoming empty state + receding chat chrome (federation-gated); the live "Working… Ns"
  thinking timer; empty-trace "view" suppression. Off-view byte-identical; full suite green.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.32 — Clickable Conversation Navigation (Stage A — the consulted record becomes a door)

## Why
The sources rail under each answer listed the records the desk consulted — but they only
linked *out* to the status browser. The most natural next move in a reference interview —
"tell me more about *that* one" — required the patron to retype it. v0.32 makes a consulted
record a door back into the conversation: an inline **ask-link** that asks the desk about
that record, in place, without leaving the page. (Stage A of clickable navigation; Stage C —
the agent reasoning its *own* next questions — lands in v0.35.)

## What

### Inline ask-links from consulted records
Federation-gated. Each record the turn consulted gains an affordance that, clicked, submits a
follow-up scoped to that record — the conversation continues by pointing, not by typing. The
links ride the same client-correlated record metadata the v0.29 citation rail already builds;
no new wire data.

### Bug fix: the search widget's `:records` key
The `search` tool widget read its results under the wrong key and silently rendered empty.
Fixed to the correct `:records` key — a consulted-records list that was quietly blank now
populates, which is also what gives the ask-links anything to point at.

## Honesty notes
- Federation OFF / single-shot byte-identical — ask-links exist only on the federated surface.
- The `:records` fix is a real silent failure closed (rule 3): the widget rendered without
  error but with no content; the corrected key restores the data the citation/ask-link layer
  depends on.

## Done = all of:
- Inline ask-links from consulted records (Stage A, federation-gated); search-widget
  `:records` key fix. Off-view byte-identical; full suite green.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.33 — Streaming Federation Answers (the agentic loop learns to stream)

## Why
Every modern chat streams its answer; the Reference Desk didn't. The single-shot path already
streamed, but the **agentic federation path** did not — `Chat::Loop` called the non-streaming
`converse_with_tools`, got the whole final answer, and emitted it as one `:token`, so the
answer *popped in* after ten to thirty seconds of nothing. The blocker was specific: the
gateway's stream path streamed content but **always returned empty tool_calls** — it never
assembled tool calls from the stream, so the loop couldn't simply flip to streaming (the first
round is usually tool calls, which would be dropped). v0.33 adds the missing piece — streamed
tool-call assembly — so the loop can stream the final answer while grounding survives.

## What

### `Gateway#converse_with_tools` — streamed tool-call assembly (`adapters/llm/gateway.rb`)
The streaming branch now accumulates **tool-call deltas** alongside content. OpenAI emits tool
calls fragmented across chunks (`choice.delta.tool_calls`: an array of `{index, id?,
function:{name?, arguments?}}`); a tolerant `extract_tool_call_deltas` captures `id`/`name`
when present and **concatenates** `arguments` fragments by index. At stream end: if fragments
accumulated, it builds `tool_calls` and the `assistant_message` in the **same shapes** the
non-stream path produces (so the loop can't tell the difference); otherwise it returns the
streamed content as before. `tokens: {}` on the stream path, unchanged.

### `Chat::Loop` — stream the call, with a no-double-emit guard (`chat/loop.rb`)
The loop calls `converse_with_tools(stream: true)` with a block that emits each delta as a
`:token` and sets a `streamed` flag. The load-bearing line is `emit(:token, …) unless
streamed`: with a real streaming gateway the block fires and the text already streamed (no
double-emit); with a non-streaming adapter or the test `ScriptedLLM` (which ignores the block)
`streamed` stays false and the full text is emitted exactly as before — so **every existing
loop spec stays green unchanged**. Tool rounds emit no content and dispatch as today. The
enforcement boundary (route_to interception, allow-list, grounding) is untouched.

### Client — unchanged
The federated `:token` handler already accumulates and renders via the debounced `mdToHtml`;
the answer bubble is created lazily on the first token. Streamed deltas flow through all of it
with no change. No new SSE event — streaming reuses `:token`.

## Honesty notes
- **Federation-path only.** The single-shot streaming path and the off-view are untouched;
  byte-identity-when-off holds.
- **Budgets are between rounds.** A streaming *final answer* is not chopped mid-flight
  (correct — you don't truncate the answer); the per-call `gateway_timeout` still bounds a
  wedged stream.
- **Error mid-stream** routes to the v0.30 `:error` card; any partial streamed text is
  replaced by the card (acceptable). We stream the answer's *content*; tool-call arguments
  assemble silently, as before — streaming them to the UI is out of scope, named.

## Done = all of:
- `Gateway#converse_with_tools` streamed tool-call assembly (`extract_tool_call_deltas`,
  fragment concatenation by index, non-stream-identical `tool_calls`/`assistant_message`
  shapes); `Chat::Loop` streaming with the `unless streamed` guard (existing loop specs green
  unchanged; one new real-streaming loop case); gateway streaming specs proving assembly from
  fragmented chunks. No new SSE event; off-path byte-identical; full suite green.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.34 — Follow the Stream (auto-scroll; the Sources rail collapses)

## Why
With the answer now streaming (v0.33), two surface frictions surfaced: the page didn't follow
the growing answer, so the patron had to scroll to keep the newest text in view; and the
"Sources consulted" rail sat open under every answer, pushing the next exchange down the page.
v0.34 makes the room follow the writing and tuck the sources away until wanted.

## What

### Follow-the-stream auto-scroll
Federation-gated. As tokens stream in, the view keeps the newest text in view — but yields to
the patron: if they scroll up to read, auto-scroll stops fighting them and resumes only when
they return to the bottom. A "follow the stream" affordance, not a scroll-jack.

### The Sources rail collapses into a closed `<details>`
The numbered sources rail is now a closed `<details>` by default — present, one click away,
but no longer occupying the space between turns. The inline citation chips in the prose are
unchanged; the rail is the redundant, browsable copy, so collapsing it costs nothing.

## Honesty notes
- Federation OFF / single-shot byte-identical — both behaviors live on the federated surface
  only.
- A client refactor extracted `followStream`; the error-card path now calls it, so the client
  test factory injects a `followStream` noop (a test-seam detail, no behavior change).

## Done = all of:
- Follow-the-stream auto-scroll (yields to manual scroll, resumes at bottom); Sources rail
  collapsed into a closed `<details>`. Off-view byte-identical; client golden/cite tests
  green; full suite green.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.35 — Agent-Reasoned Follow-ups (Stage C — the desk helps you ask)

## Why
The follow-up suggestions under an answer were generic and unchanging — the same placeholders
no matter the question. A reference interview's value is partly the librarian *seeing the next
good question* the patron didn't know to ask. v0.35 makes the agent **reason its own
follow-ups** from the turn it just answered, rendered as clickable questions that continue the
inquiry — and instruments the click-through, because the experiment is the point: we are
funded to learn what the surface can become.

## What

### `Chat::Followups` — the inline follow-up protocol (`chat/followups.rb`)
A small protocol object: a `SENTINEL` (`%%FOLLOWUPS%%`), a `MAX` of 3, a `DIRECTIVE` appended
to the system prompt instructing the desk to end its answer with the sentinel followed by up
to three contextual next questions, and `parse(text)` — which splits at the sentinel
(`take_while`, so a stray second sentinel can't smuggle body text), strips bullet/number
markup, and caps at `MAX`. The questions are *contextual* — reasoned from this answer, not a
static list.

### `Chat::Loop` injects the directive + emits `:followups` (gated)
When `config.chat_followups` is on, the loop appends the directive to the system prompt and,
after the final answer, parses the tail and emits a `:followups` event with the questions.
The directive is composed into the system prompt centrally (this becomes `compose_system` in
v0.36), not hand-concatenated at the call site.

### Client renders server-reasoned follow-ups; the scaffold retires
The federated client renders the `:followups` event as clickable question buttons that submit
as the next turn, and `proseOf` **strips the sentinel and its tail** from the streamed prose
so the protocol marker never shows (golden-guarded). The earlier client-side DOM-scrape
scaffold that guessed follow-ups from consulted records is **retired** — the agent's reasoning
replaces the heuristic.

### Instrumentation
The controller logs follow-up **click-through** (gated, the query truncated) so we can see
which reasoned questions patrons actually pursue — the measurement the version exists to
enable. The `:followups` event is gating-pinned: OFF → absent, ON → parsed questions.

## Honesty notes
- `config.chat_followups` is **OFF by default**; OFF is byte-identical (no directive, no
  `:followups` event, the prose unchanged). The sentinel-strip is golden-guarded so a normal
  answer is never altered.
- Follow-ups are *reasoned*, not retrieved — they are the model's suggestion, shown as such;
  clicking one is a new grounded turn, governed by the same Loop.

## Done = all of:
- `Chat::Followups` (sentinel/MAX/DIRECTIVE/`parse` with `take_while` truncation guard);
  `Chat::Loop` directive injection + `:followups` emission (gated); client renders clickable
  follow-ups + `proseOf` sentinel-strip (golden-guarded), DOM-scrape scaffold retired;
  controller click-through logging (gated, truncated); `:followups` gating pinned. OFF
  byte-identical; full suite green.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.36 — The Reference Register (the desk's voice, engine-owned)

## Why
The desk answered correctly but in no particular *voice* — sometimes a chipper "friendly
assistant," wrong for a homeland-security research library. The right voice is
institutional-formal: a reference librarian's register — precise, unhurried, never chummy,
never hedging into uncertainty it doesn't have. v0.36 gives the engine an **owned register**
that sits beneath every desk's persona, so the whole federation speaks the institution's voice
by default, and establishes the composition seam that v0.37's editable personas plug into.

## What

### `Chat::Register` — the engine-owned voice (`chat/register.rb`)
`Register::DEFAULT` is a frozen, institution-formal LIS register: how the desk carries itself,
independent of any one desk's role. It is **code-owned** — the institution's voice, not a
per-deployment knob — gated by `config.chat_register`.

### `Chat.compose_system` — register → persona → followups
A single composition function builds the system prompt the Loop sends:
`[register_text, persona_text, (Followups::DIRECTIVE if chat_followups)].compact.join`. The
register frames the voice; the persona (the agent's `system_prompt`, made editable in v0.37)
frames the role; the follow-up directive (v0.35) rides last. The Loop calls `compose_system`
at run init **and** on every handoff reset, so a specialist inherits the same register. This
is the seam that makes the persona safe to edit: the register and the Loop's enforcement are
not in the persona's reach.

### Patron-voiced follow-ups
With a register in place, the v0.35 follow-up directive is tuned to the patron's voice — the
suggested questions read as a patron would ask them, not as the desk describing itself.

## Honesty notes
- `config.chat_register` gates the register; composed centrally, so register/persona/follow-ups
  can't drift apart at call sites. With federation off the system prompt is the agent's own
  `system_prompt`, unchanged.
- The register is the institution's voice and stays code-owned; what a deployment edits (v0.37)
  is the per-desk **persona**, never the register.

## Done = all of:
- `Chat::Register::DEFAULT` (institution-formal, frozen, `config.chat_register`);
  `Chat.compose_system` (register → persona → followups) used by the Loop at init and handoff;
  patron-voiced follow-up directive. Off-path unchanged; **663 green.**
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.37 — Persona Editing (code seeds, the store governs)

## Why
A deployment needs to shape each desk's *persona* — the CHDS Theses specialist should
introduce itself as such — without editing the gem. And those edits must be auditable and
reversible: a voice is a governance surface, not a config string. v0.37 makes each desk's
persona **curator-editable, versioned, and rollback-able**, applying the authority-control
pattern the vocabulary already uses — **code seeds, the store governs** — now to the desk's
voice. It is safe to do because the Loop, not the persona, enforces behavior.

## What

### `Chat::Persona` — an append-only versioned store (`models/enliterator/chat/persona.rb`)
A new table `enliterator_chat_personas` (reversible migration; applied to the dummy and HSDL
dev). `record(desk_name:, system_prompt:, editor:, note:)` appends a version;
`effective(desk_name)` returns the latest stored persona or nil; `history(desk_name)` lists
versions newest-first. **Append-only** — a rollback is a new version copying an old one, not a
deletion, so the audit trail is complete.

### The Loop resolves the effective persona (override || seed)
`Chat::Loop#persona_for(agent)` resolves `Chat::Persona.effective(agent.name) ||
agent.system_prompt` — the stored override if one exists, otherwise the code seed — and feeds
it through `Chat.compose_system`. The change is **live on the next turn**: the store governs,
the code seeds. The register and enforcement are untouched.

### `/desks` — the persona editor (`DesksController`, gated)
A new surface (`desks`, `desks/update`, `desks/rollback`). It shows each registered desk's
editable persona, the **read-only** engine register and org chart (tier, tools, routing —
code-owned), the **composed preview** (exactly what the Loop sends), and the version history
with per-version rollback. Gated by `config.chat_persona_editing` — the route is always drawn;
the controller `head :not_found` when off (the always-draw + gate convention shared with
chat/mcp). An **editor seam** (`config.chat_editor`, a callable over the request) attributes
each version to a person when the host resolves one, rescuing to nil otherwise — auth-agnostic.

## Honesty notes
- `config.chat_persona_editing` OFF: `/desks` 404s and nothing reads the store —
  byte-identical. With it on but no edits saved, `effective` is nil and the Loop uses the code
  seed — still byte-identical to v0.36.
- **The persona is editable because behavior isn't in it.** Grounding, the read-only
  allow-list, provenance, routing — all live in the Loop. A curator can rewrite the voice; they
  cannot rewrite what the desk is allowed to do.
- Append-only by design: history is never destroyed; rollback is a forward-moving copy.

## Done = all of:
- `Chat::Persona` (append-only versioned store, `enliterator_chat_personas`, reversible
  migration applied to dummy + HSDL); `Chat::Loop#persona_for` (override || seed via
  `compose_system`, live next turn); `/desks` editor (editable persona, read-only
  register/org-chart, composed preview, history + rollback) gated by
  `config.chat_persona_editing` (always-draw + controller-gate); `config.chat_editor` editor
  seam (rescued, auth-agnostic). OFF byte-identical; full suite green.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.38 — Per-Agent Step Cap + No-Browser Evaluation (the desk becomes testable)

## Why
Two needs converged. First, a thorough specialist (CHDS Theses) sometimes exhausted the
federation's default step budget on hard questions and returned "I reached my step budget"
instead of an answer — the cap belonged to the desk, not the federation. Second, evaluating
the desk meant driving the browser by hand: slow, unscriptable, and it hid the run-to-run
variance the agentic loop actually has. v0.38 makes the step cap **per-agent** and gives the
engine a **no-browser way to evaluate a desk** — drive `Chat::Loop` directly and get the
answer, the tools used, the handoffs, the follow-ups, and the elapsed time back as data.

## What

### Per-agent `step_cap`
`Chat::Agent` gains a nilable `step_cap`; `Chat::Loop` uses `effective_step_cap =
@agent.step_cap || @step_cap` — a desk that needs more rounds (HSDL's CHDS desk: 10) gets
them, while the federation default still bounds the rest. A thorough question that previously
hit the budget now completes.

### `Chat::Eval` — drive the loop without a browser (`chat/eval.rb`)
`Eval.ask(question, context:, record:, **loop_opts)` runs the real `Chat::Loop` and returns a
`Result` struct: `answer`, `tools`, `handoffs`, `followups`, `elapsed_s`, `budget_hit`, and the
raw `events`. It is the loop the controller drives, minus the transport — so an eval exercises
the genuine governed path, not a mock. When `config.chat_retention` is on (v0.39) an eval
records like any turn.

### `enliterator:ask` — the rake front door
A rake task wraps `Eval.ask` so a desk can be questioned from the command line in a `rails
runner` — scriptable, fast, and honest about variance (run it three times and watch the
agentic path differ). This is the harness that found the step-budget bug in the first place.

## Honesty notes
- The per-agent cap is additive: an agent with no `step_cap` behaves exactly as v0.37 (the
  federation default applies). Off-path unaffected.
- `Eval` drives the **real** Loop — same enforcement boundary, same tools, same budgets — so an
  eval result reflects production behavior, not a simulation. It records only when retention is
  enabled.

## Done = all of:
- `Chat::Agent#step_cap` (nilable) + `Chat::Loop` `effective_step_cap` (per-agent || federation
  default); `Chat::Eval.ask` → `Result` (answer/tools/handoffs/followups/elapsed_s/budget_hit/
  events), driving the real loop, recording under retention; `enliterator:ask` rake (no-browser
  desk evaluation). Additive; off-path unaffected; full suite green.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.39 — Chat Retention (the event stream is the artifact)

## Why
Demonstrating the desk meant starting a fresh conversation and running it live every time; and
the tending loops the project wants to build *on the desk's own conversational quality* had
nothing to tend — the turns evaporated when the stream closed. v0.39 retains every federation
turn as a first-class artifact and can **replay it**. The insight that makes this cheap: the
SSE event array the desk already streams **is** the transport, **is** the record, **is** the
replay source, **is** the future tending input. Capture is teeing the sink; replay is
re-emitting the array.

## What

### `Chat::Conversation` + `Chat::Turn` — the store (gated)
Two new tables (reversible migrations; applied to the dummy and HSDL dev):
`enliterator_chat_conversations` (token, context, label, source) and `enliterator_chat_turns`
(conversation, ordinal, question, **events jsonb**, answer, desk_name, persona_id, elapsed_ms,
budget_hit). The turn's stored `events` jsonb is the captured SSE array verbatim — the
artifact. `Turn` is built **tendable-ready**: the fields a future conversation-quality facet
needs (the answer, the desk, the persona version, the events) are already first-class. Gated by
`config.chat_retention`.

### Capture = tee the sink (`Chat::Recorder` + controller)
When retention is on, `ConversationController#stream` wraps its SSE sink so each event is
**both** written to the wire and appended to a captured array; at turn end
`Chat::Recorder.record` persists it. The recorder derives `answer`/`desk_name`/`persona_id`/
`budget_hit` from the event array, tolerates symbol- and string-keyed events, and **never
raises** (it rescues and logs — a retention failure must never break a live turn, rule 3).
`Chat::Eval` records through the same path. The client carries a `conversation_token` so a turn
joins its conversation (gated).

### Re-stream replay (endpoint + client)
`GET /chat/replay/:id` **re-emits a stored turn's events as SSE** — the same event types in the
same order — so the federated client renders a replay **identically to a live turn**, with zero
model spend. A small inter-token delay (skipped in test) preserves the live feel; replay frames
`replay_user`/`replay_end` bracket the re-stream. The replay client reuses the live federated
renderer — one renderer, two sources.

### `/conversations` — browse + label (gated)
A new surface lists retained conversations with their source (live vs eval), labels them, and
deletes them. The delete confirm uses an inline vanilla `onclick` confirm, **not** Turbo/UJS
`data-confirm` (the engine ships no JS framework — a `data-confirm` would be a dead no-op on a
destructive action; rule 2).

## Honesty notes
- `config.chat_retention` OFF: the sink is the plain `sse` method, nothing is stored, and
  `/conversations` / `/chat/replay` 404 — byte-identical to v0.38.
- **The event array is the single source.** Replay does not re-run the model or reconstruct —
  it re-emits exactly what was captured, so a replay is a faithful record, not an
  approximation. Live-verified: a captured live turn (source=live) replayed from the store with
  zero Bedrock, rendering indistinguishably from live.
- Retention is **designed for** the next phase (conversation-tending: `Turn` as a Tendable +
  quality facets) but does not implement it — named, not pretended.
- The ordinal-assignment race (MAX+1) is UI-unreachable and logged on the unique index —
  accepted, not hidden.

## Done = all of:
- `Chat::Conversation` + `Chat::Turn` (events-jsonb-as-artifact, tendable-ready fields,
  reversible migrations applied to dummy + HSDL); `Chat::Recorder` (derives answer/desk/persona/
  budget_hit, symbol+string tolerant, never raises); tee'd capture in
  `ConversationController#stream` + `Chat::Eval`; client `conversation_token`; re-stream replay
  endpoint + client (reuses the federated renderer, `replay_user`/`replay_end`); `/conversations`
  browse/label/delete (inline `onclick` confirm). All gated by `config.chat_retention`; OFF
  byte-identical; **715 green** (retention proven: live turn captured → replay re-streamed from
  store with zero model spend).
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.40 — `enliterating-a-collection` (the method, shipped in the gem)

## Why
Across HSDL the engine taught us not just *a* tool but a *method*: how to take a collection
from dormant to enliterated — the facet and staffing design, the vocabulary discipline, the
condition survey, the heartbeat economics, the measured audit, the reference-desk pattern, and
the ethic of who owns the spend. That method is a transmissible literacy. v0.40 encodes it as a
**skill shipped in the gem** — so the next enliteration starts from the accumulated practice,
not from scratch. It is written as an explicit **first draft, to be tended through the lens of
every use** — itself an enliterated artifact, with a Tending log.

## What

### `skills/enliterating-a-collection/SKILL.md`
A skill that ships in the gem at `skills/enliterating-a-collection/`. It encodes:
- the **stance** — build IN to library/information science, don't reinvent it (authority
  control, SKOS, PROV-O, finding aids);
- the **method** — derive text first (the foundation for non-text collections), design facets
  as roles and tiers as capability, let the vocabulary govern itself, survey condition before
  spending, run the heartbeat on the changed frontier, measure the audit, staff a reference
  desk;
- the **common mistakes** (from its own RED baseline: generic "AI enrichment," invented
  vocabulary, tending records no one can read) and their LIS-grounded corrections (TGM/TGN/
  LCNAF, legibility-gating, the measured audit);
- the **ethic** — the conscience is human; someone sees the dormant collection and authorizes
  the spend.

### Written test-first; tended on first use
The skill was authored RED→GREEN (a museum-photo-archive baseline missed LIS grounding,
invented vocabulary, tended unreadable records; with the skill it used TGM/TGN/LCNAF,
legibility-gating, and the audit). It carries a **Tending log** — Visit 0 (HSDL, its source
corpus) and Visit 1 (a photo archive, which taught the derive-text-first foundation for
non-text collections) — and declares itself a first draft to be tended through every use.

## Honesty notes
- This is **documentation shipped in the gem**, not engine code — no runtime change, no new
  surface, suite unaffected. Its correctness is demonstrated by the RED→GREEN authoring and the
  Tending log, the same way a skill is tested.
- The method is **HSDL-shaped and text-native today** — it explicitly wants a second, ideally
  non-text, collection to settle its open questions. The next enliteration is its Visit 2; the
  draft expects to change.

## Done = all of:
- `skills/enliterating-a-collection/SKILL.md` — the method (stance, the step-by-step method, a
  common-mistakes table from a RED baseline, the ethic), written RED→GREEN, encoded as a first
  draft with a Tending log (Visit 0 HSDL, Visit 1 photo archive). Ships in the gem; no runtime
  change; suite unaffected.
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.41 — Reset to Seed (the persona editor, completed)

## Why
v0.37 let a curator edit a desk's persona but gave no honest way *back* to the registered
seed — short of pasting the gem's text by hand. A persona editor isn't finished until you can
return to the code-owned starting point, auditably. v0.41 adds reset-to-seed and, in doing so,
closes the v0.37 surface.

## What

### `DesksController#reset` — an append-only return to the seed
Reset records a **new version copying the registered seed** (`desk.system_prompt`), rather than
deleting the override history — the reset is itself an auditable version, consistent with the
append-only store. After a reset, `effective` equals the seed again.

### The Reset affordance shows only when overridden
`/desks` computes `overridden = effective != desk.system_prompt` and shows the Reset button
(with an inline vanilla `confirm`) **only when the persona genuinely differs from the seed**. A
desk on its seed reads "using the registered seed" and offers no reset; the status line makes
the override state legible at a glance.

## Honesty notes
- Reset is append-only and honest: history is preserved, the reset is a forward-moving copy of
  the seed, and the affordance hides when there's nothing to reset. Gated with the rest of
  `/desks` by `config.chat_persona_editing`.
- Inline `onclick` confirm (no UJS/Turbo — rule 2), matching the v0.39 delete affordance.

## Done = all of:
- `DesksController#reset` (records a seed-copy version, append-only); `/desks` `overridden`
  computation + conditional Reset affordance (inline confirm) + override status line. Gated; OFF
  byte-identical; **717 green.**
- SPEC, README, CLAUDE.md, About colophon.

---

# v0.41.1 — Graceful Bedrock Unavailability (the grant survives bedrock's bad moments)

## Why
**All** enliteration runs on a $10k AWS Bedrock credit — there are no funds for any other model, so
there is **no fallback**: the whole pipeline must *survive* bedrock's transient failures, not route
around them. Two such failures kept poisoning the nightly cycle. (1) A manually-renewed AWS SSO
session lives only ~9 hours, while the pacemaker beats at 01:30 — so an unattended beat **always**
meets an expired token until the NPS-IAM key (non-expiring credentials) lands (id=55). (2) Even on a
valid token, a bedrock call can **time out** mid-cycle (id=54, id=56 — the considerer, which runs on
bedrock, timed out on the 4th of ~5 scopes). The intended behavior for both is a **pause**: defer the
work, finish the cycle clean, resume on the next beat. It wasn't. The heartbeat had no notion of a
transient failure — the only expiry-recognition lived in `Chat::ErrorReport` (the chat surface) and
the pacemaker never consulted it. So a transient failure either tripped the `EARLY_FAILURE_LIMIT`
misconfiguration abort (tokens=0) or surfaced as the cycle's terminal `error` — skipping the
considerer/conservator/audit and exiting non-zero. The considerer stalled for days.

## What

### `Enliterator::Adapters::LLM::Bedrock.unavailable?(error)` — the defer gate
The predicate the heartbeat consults to decide *defer-and-resume* vs *fatal*. It is the union of two
recognizers, matched against `"#{error.class}: #{error.message}"`:
- **`auth_lapsed?`** — the AWS-credential-expiry signature (`ExpiredToken | security token … expired
  | InvalidGrant | sso`) **ANDed** with a bedrock scope (`/bedrock/i`). True only for a recoverable
  bedrock auth lapse; false for a non-bedrock token expiry (*only-on-bedrock*) and for a bedrock error
  that is not an auth lapse (throttling). Covers both the direct-SDK error and the LiteLLM 500. Shares
  the expiry signature with `Chat::ErrorReport`'s SSO hint, which stays an independent, any-tier concern.
- **`TRANSIENT_RX`** — timeouts / connection blips / 5xx (`APITimeout | Net::ReadTimeout | timed out |
  ECONNREFUSED | Connection(Failed|Reset) | ServiceUnavailable | 502/503`). A timeout carries no tier
  marker, but deferring-and-retrying a timeout is safe on **any** tier, so this half is intentionally
  not bedrock-scoped. A real fault (bad request, model-not-found, a bug) matches neither → stays fatal.

Pure string match — never loads the AWS SDK, so the heartbeat may call it on any host (the engine does
not depend on `aws-sdk-bedrockruntime`).

### The heartbeat defers in place where it can, finishes clean everywhere
- **`work_items!`**: a per-item transient failure **defers** the record — it stays on the frontier,
  untended, with no Visit, counted in a lazily-added `deferred` tally — and does **not** count toward
  `EARLY_FAILURE_LIMIT`, so a transient outage at the start no longer reads as a misconfiguration. One
  summary warning per cycle names the deferred count and the `aws sso login` remedy (if SSO expired).
- **`consider!`**: a transient failure in a scope **holds that scope** for the next beat; scopes
  already considered stay saved (the `update!` still runs) and the cycle continues. (This is exactly
  id=56: a timeout on the 4th of ~5 scopes now preserves the first three instead of losing them.)
- **`execute!`**: the top-level rescue treats a transient failure as a **clean finish** — no `error`
  stamp, no re-raise (exit 0) — the backstop for any phase that does not defer in place. Every other
  error stays fatal exactly as before.

The deferred work resumes on the next beat that runs with a valid, responsive token: a manually-
triggered daytime beat now, every nightly beat once the IAM key removes the expiry.

## Honesty notes
- **Transient defers; real faults stay fatal; additive.** A real failure (bad request,
  model-not-found, a bug) still counts and the `EARLY_FAILURE_LIMIT` abort still fires on it
  (spec-pinned). Only transient unavailability (expiry / timeout / connection / 5xx) defers. The
  `deferred` tally is added only on a real deferral, so a cycle with none is byte-identical to v0.41.
- **Scoping.** The auth half is bedrock-scoped (an expiry signature ANDed with `/bedrock/i`) so a
  non-bedrock SSO error can't mis-defer. The timeout/connection half is intentionally tier-agnostic —
  retrying a timeout next beat is safe on any tier — which also matches this deployment's reality:
  **all enliteration is on bedrock** (no funds for any other model, so no fallback exists).
- This fixes the **engine** half. The **operational** half — the ~9h SSO window never overlapping the
  01:30 beat — is closed only by the NPS-IAM key (non-expiring credentials). Until then the graceful
  defer keeps every cycle clean and the bedrock lane drains on any valid-token beat.
- **No config flag**: the trigger (transient bedrock unavailability) is itself the gate, and it was a
  previously-always-fatal condition. A flag to re-enable the broken behavior has no use case.

## Done = all of:
- `Enliterator::Adapters::LLM::Bedrock.unavailable?` = `auth_lapsed?` (`AUTH_EXPIRY_RX` ∧ `BEDROCK_RX`)
  ∨ `TRANSIENT_RX` (timeout/connection/5xx) — SDK-free; `work_items!` per-item defer + lazy `deferred`
  tally + summary warning; `consider!` per-scope hold; `execute!` top-level clean-finish net. Real
  faults stay fatal; no-deferral cycles byte-identical; **735 green** (18 new: the predicate's auth +
  transient + only-on-bedrock + real-fault cases, the defer-and-continue, the no-abort-on-all-lapse,
  the no-abort-on-all-timeout, the considerer auth-hold and timeout-hold, the top-level net, and a
  back-compat guard that a non-bedrock failure stays fatal).
- SPEC, README, CLAUDE.md, About colophon.

---

# Authority control is two-stage (foundational)

*Not a version — a foundational reframe of how the vocabulary governs itself. Discovered 2026-06-17
while supervising a considerer run on chds-theses (~1,135 open candidate terms in one scope, 68%
proposed by a single record). The conceptual pass was documentation-only; **stage 1 then shipped in
v0.41.2** (below) — the candidate block + affirmation, gated behind `read_time_warrant` and
byte-identical when off. Semantic-nearest candidate retrieval and the index/value audit remain
forward work.*

## The thesis

Literacy is not curated onto a corpus after the fact; it **emerges from the act of reading it**. A
collection's controlled vocabulary — the terms by which it can be searched, browsed, and understood
— is built by the readers of its documents, each recognizing what a document is about *and what
prior readers already named*. Authority control is therefore not an editorial stage bolted on at the
end; it is **distributed across every act of reading, and merely ratified centrally**.

This is how a thesaurus is actually maintained (ANSI/NISO **Z39.19**): an indexer works with the
vocabulary *in hand* — reusing established terms and proposing candidate terms by **literary
warrant** — and an editor ratifies. The engine's thesis, made infrastructure: *the controlled
vocabulary is an emergent property of reading, not an imposition upon it.*

## The two stages

- **Stage 1 — read-time warrant accrual (distributed).** As a reader tends a record it sees *both*
  the **established vocabulary** (approved terms it uses as claim keys) *and* the **candidate
  vocabulary** (open proposed terms already carrying warrant — what other readers recently
  proposed). It reuses established terms, **affirms** a candidate when one fits (contributing
  warrant), and proposes a genuinely new candidate only when neither fits. Convergence happens here,
  where the literature is read.
- **Stage 2 — ratification (centralized).** The `Considerer` synthesizes the converged candidate
  field and ratifies a slate (map / approve / reject); approvals join the established vocabulary;
  `/requests` is the human ratification surface.

The model maps onto what already exists, and onto Z39.19:

| Z39.19 | Enliterator |
|---|---|
| established / preferred terms | `Vocabulary.for(facet, context:)` (code + curator-approved) |
| candidate terms | `Suggestion` (pending — the live read-time projection readers affirm, via `Suggestion.gaps`) + `ProposedTerm` (the materialized warrant aggregate the `Considerer` reads) |
| literary warrant | `pressure` / `distinct_records` / resurgence |
| vocabulary editor | `Considerer` + `/requests` |

## What's true today, and what isn't

**Stage 2 exists and works.** The considerer reads the whole candidate field, decides each term,
auto-applies the reversible verdicts (maps + confident rejects), and holds approves for human
ratification — exactly the editor's role.

**Stage 1 was degenerate (v0.41.2 fixes it).** The reader was given only the *established*
vocabulary (the facet contract, `Vocabulary.for`); it never saw the *candidate* field. So every
reader proposed blind: warrant accrued only when two readers happened to coin the identical key
string, and synonyms (`issuing_organization` / `issuing_agency` / `organization_origin`) piled up as
separate candidates. **We built indexers who could not see the thesaurus.** The considerer inherited
the fragmentation as one oversized field — chds-theses presents ~1,135 open candidates, 68% proposed
by exactly one record — which is both why a single whole-field synthesis call times out and why most
of the field is noise. v0.41.2 shows the reader the candidate field; see below.

## Stage 1 — read-time warrant accrual (shipped in v0.41.2)

Two reader-side disciplines, both "participate in vocabulary formation correctly":

**(a) Show the candidate vocabulary; let readers affirm.** Thread a **candidate block** into the
tend prompt beside the established contract: a *bounded, warrant-ranked* set of open candidates for
this facet/context — **top-N by `Suggestion.gaps`** (the live *pending* demand, read directly at
tend-time so a key proposed earlier in the same cycle is already visible; the considerer's
`ProposedTerm` aggregate is materialized only at consider-time and would read stale here). The
instruction goes three-tier: *established* → use as a claim key; *candidate* → if one expresses your
observation, re-propose **that** key (affirm it); *novel* → propose a new candidate only when
neither fits. "Affirming" is emitting the same `proposed_key`; the existing Suggestion → ProposedTerm
machinery already aggregates it (warrant = `COUNT(DISTINCT tendable)`), so warrant accrues with **no
new storage**. Guards: affirm only if it genuinely fits (a forced match is worse than a clean new
proposal), and never emit a candidate as a *claim* — it isn't established yet. Semantic narrowing to
candidates near this record is deferred; top-N-by-warrant is the shipped MVP.

**(b) Subject-indexing vs vocabulary-proposal.** Separate two acts the reader now conflates:
*indexing this document's subjects* (a **value**, e.g. under `index_terms`) vs *proposing a new
collection-wide dimension* (a new **key**). The test: a document-specific concept becomes an
`index_terms` value; a new candidate *key* is reserved for a concept many records would share. This
is what stops the long tail — a thesis's bespoke "five-element framework" is an index value, not a
vocabulary key.

(a) collapses synonyms; (b) keeps bespoke one-offs out of the key space. The considerer then
ratifies a small, genuinely-warranted, collection-level field.

## Consequences for the existing design

- **Supersedes "chunk the considerer."** The earlier instinct — batch the oversized considerer call
  — treated the symptom. Upstream convergence shrinks the candidate field at the source; the
  considerer's whole-field synthesis (its load-bearing property: it can only dedupe terms it sees
  together) stays intact, just over a converged field. A pressure-floor on what the considerer
  LLM-considers drops from "the fix" to a backstop.
- **Pressure becomes a true warrant signal.** Today pressure is coincidental string-collision; with
  the candidate block, an affirmation is a reader of the literature recognizing a term — pressure
  *is* literary warrant, accrued where reading happens.

## Non-goals / deferred to the implementation plan

Stage 1 shipped in **v0.41.2** under the usual discipline (additive, gated behind
`read_time_warrant`, byte-identical when off). Resolved along the way: the read-time source is
`Suggestion.gaps` (live pending), so a reader sees candidates accrued *within* the running cycle,
not just prior warrant. Still deferred: semantic-nearest candidate retrieval (vs top-N-by-warrant)
and N-tuning; an audit of the index/value discipline. One risk to carry: the candidate block creates
a rich-get-richer effect — mostly the point (convergence), but it can entrench an early poor term;
stage 2 (the considerer) remains the corrective.

---

# v0.41.2 — Read-time warrant accrual (stage 1, built)

## Why
The foundational reframe above named the model and diagnosed the break: readers were shown only the
*established* vocabulary (`Vocabulary.for`) and never the *candidate* field, so each proposed blind —
synonyms fragmented (`issuing_organization` / `issuing_agency` / `organization_origin`) and a one-off
tail piled up (chds-theses: ~1,135 open candidates, 68% from a single record), which floods the
considerer and times out its whole-field synthesis. This version builds **stage 1**: show readers the
candidate field and let them **affirm** an existing candidate instead of coining a synonym. Reader-side
only; the considerer (stage 2) is unchanged — it just ratifies a smaller, converged field. This
**supersedes** the earlier "chunk the considerer" instinct (a pressure-floor drops to a backstop).

## What

### `config.read_time_warrant` — one flag, default off
`attr_accessor` in the chat-flag cluster; nil default, reset each example. Off ⇒ no candidate
retrieval, no prompt change, the adapter call is **byte-identical** to v0.41.x. This is hard rule 1,
spec-pinned (the flag-off visitor never even calls `candidates_for`).

### `Enliterator::Vocabulary.candidates_for(facet, context:, established: nil, limit: 20)`
The bounded, warrant-ranked CANDIDATE vocabulary a reader is shown — symmetry with `Vocabulary.for`.
It is `Suggestion.gaps` (live **pending**, ranked by `COUNT(DISTINCT tendable)`) minus two exclusions,
returning `rows.presence` (**nil, not `[]`**, when empty — so the visitor's `!candidates.nil?` gate
omits the kwarg):
- **established** — path-cumulative `Vocabulary.for` (code + curator-approved). `established:` lets the
  visitor pass the contract it already resolved, avoiding a per-record recompute; the `Vocabulary.for`
  fallback serves standalone/test callers. String-normalized to match gap keys.
- **resolved** — `Suggestion.resolved_keys(context:)` (approved / mapped / rejected, read **up** the
  path). Excluded so the block never advertises a key whose affirmation `persist_suggestions!` would
  silently drop (mapped/rejected in an ancestor while a child still holds pre-verdict pending rows).

Scoping is **asymmetric and load-bearing**: candidate-gathering uses the **exact** context
(`gaps`' `context_id: context&.id` — pending rows don't inherit, rule 4); exclude-established uses the
**path-cumulative** `Vocabulary.for`/`resolved_keys` (verdicts read up the path). Read-time source is
`Suggestion.gaps`, **NOT** `ProposedTerm` — `ProposedTerm.refresh!` runs only at consider-time, so
reading it here would show stale warrant and return `[]` on a host between considerer runs (a
fantasy-state no-op). Reading live `gaps` also means a key proposed earlier in the **same cycle** is
visible to later readers (within-cycle convergence, free). Renders `proposed_key` + `count` +
`sample_rationale` — the exact gap-hash keys.

### The candidate block (`Adapters::LLM::Base#candidates_block`)
`system_for(contract, required:, candidates:)` appends `candidates_block` as a **sibling** after
`contract_system_block`, guarded by `candidates&.any?` — never nested in the contract block (it
early-returns the base text for a no-contract facet; candidates can only exist *under* a contract). The
block renders the candidate vocabulary and a **three-tier instruction**: *established* → claim key;
*candidate* → if one fits, re-propose **that** `proposed_key` (affirm); *novel* → propose a new key only
when neither fits. Discipline (b) rides the same block: a document-specific concept is a **value**
(route to a value-bearing key like `index_terms`); a new **key** is reserved for a recurring,
collection-level dimension. **The structured-output schema is UNCHANGED** — `SUGGESTIONS_SCHEMA_PROPERTY`
is added unconditionally for every contract facet, so editing its "new keys" framing would break
byte-identity; instead the gated block states explicitly that re-emitting a shown candidate's
`proposed_key` is how you affirm it, overriding the array's general framing for the candidates shown.
Affirmation lives entirely in the system prompt; the schema golden stays clean.

### Visitor threading (the verified injection path)
`call_with_staffing` computes `candidates` **once per record** — gated on
`read_time_warrant && contract` (an unconstrained facet emits no suggestions, so the `gaps` query is
skipped) — and threads it to **every** tier visit via `tend_with_optional_kwargs`, kwarg-gated exactly
like `contract:`/`required:` (passed only when non-nil AND the adapter's `#tend` declares it). So Null
and per-tier stubs are gated out; the **Gateway** (HSDL's live bedrock-sonnet path) and **Bedrock**
both thread it. The v0.1 back-compat path (`call_back_compat`) has no contract and is untouched.

## Honesty notes
- **Affirmation accrual is verified, not rebuilt.** Affirming = a reader emits an existing candidate's
  `proposed_key`; `persist_suggestions!` writes another `Suggestion` (no dedup for unresolved keys), and
  warrant is `gaps`' `COUNT(DISTINCT tendable)`. So an affirmation **by a different record** raises
  warrant (breadth of demand); a **same-record** re-tend does not (it bumps raw pressure, a separate
  signal). The persistence path is unchanged; specs pin the semantics through the real Visitor loop.
- **The model's *decision* to affirm (vs synonymize) is a deployment property**, verified live against
  HSDL — not unit-testable with a stub. The specs pin the *mechanism* the candidate block depends on.
- **Byte-identical when off.** Flag-off: no `candidates_for` call, no prompt block, the adapter call
  carries no `:candidates` key (sentinel-asserted, not just nil-asserted). Flag-on-but-no-candidates
  and flag-on-but-no-contract also omit the kwarg — three distinct no-op paths, all spec-pinned.
- **Deferred:** semantic-nearest candidate retrieval (needs candidate-term embeddings — new infra);
  the index/value audit; `ProposedTerm`'s richer signals (resurgence) at read-time. Top-N-by-warrant is
  the MVP. WATCH: `candidates_for` runs `gaps` (a GROUP BY) once per record when on — negligible beside
  the ~20s bedrock call, self-correcting as the field converges, but the first flag-on cycle over the
  ~1,135-candidate chds-theses field pays it once per record.

## Done = all of:
- `config.read_time_warrant` (gated, default off); `Vocabulary.candidates_for` = `Suggestion.gaps`
  minus path-cumulative established + resolved, exact-context, nil-when-empty; `Base#candidates_block`
  sibling-appended (schema untouched); visitor computes once per record (gated on flag ∧ contract) and
  threads to every tier visit, kwarg-gated; Gateway + Bedrock parity.
- **761 green** (26 new over the 735 v0.41.1 baseline): 9 `candidates_for` (demand order, exclude
  established + resolved, exact-context, nil-not-`[]`, limit, `established:` param + fallback), 5
  candidate-block goldens (render + byte-identity for no-contract and contract-present-candidates-absent
  + schema-untouched), 2 gateway candidate-thread, 6 visitor threading (off / on+present once-per-record
  threaded up the ladder / on+empty / on+no-contract — kwarg presence-and-absence asserted), 4
  affirmation accrual (second-record raises warrant, same-record does not, no synonym, ancestor-resolved
  suppressed). No existing example modified.
- SPEC (this section + the two-stage reframe amended to name `Suggestion.gaps` as the read-time
  source), README, CLAUDE.md, About row.
- **Gated:** push and the HSDL `config.read_time_warrant = true` enable wait on Jeremy's word; the
  live affirmation check runs against HSDL on a valid bedrock token (`enliterator:deep_read_pilot`).

---
