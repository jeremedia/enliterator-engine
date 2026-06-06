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
