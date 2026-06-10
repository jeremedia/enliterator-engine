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
