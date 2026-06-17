# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

**Enliterator** — a mountable Rails 8 engine that confers *literacy* on a host app's data:
per-record AI tending where understanding **compounds across visits**. Claims with PROV-style
provenance, reconciled (ADD/UPDATE/DELETE/NOOP) rather than overwritten; a controlled
vocabulary that governs itself (authority control); five mounted read-only surfaces.
Read `/enliterator/about` (or `app/views/enliterator/about/index.html.erb`) for the
plain-language thesis; `SPEC.md` for the full version-by-version build record.

**Stack**: Ruby 3.4.5, Rails ≥ 7.1 (dev against 8.1), RSpec, pgvector via `neighbor`,
`isolate_namespace Enliterator`, table prefix `enliterator_`. Test app: `spec/dummy`.

**First consumer**: HSDL (`/Volumes/jer4TBv3/workspaces/work/hsdl-ai`, branch
`enliterator-integration`), mounted at `/enliterator`, running through a **bundler local
override** (`.bundle/config` → this checkout), LLMs via the LiteLLM gateway
(`https://llm.domt.app/v1`, intent aliases `cheap`/`quality`/`embed`).

## Vocabulary (post-v0.12 rename — get these right)

The engine speaks **library/information science**. Use the field's terms in code, copy, and commits:

| Term | Meaning | Do NOT call it |
|---|---|---|
| **facet** | a dimension a record is read along (Ranganathan); also the tending lane (`Visit.facet`) | stream |
| **term** | an allowed claim key in a facet's controlled vocabulary (`facet name, tier:, terms: {}`) | key (except `Claim.key`, which stays) |
| **Vocabulary** | `Enliterator::Vocabulary.for(facet)` — effective controlled vocabulary (code terms + curator-authorized terms) | Contract |
| **Measure** | a quality score + signals per record (e.g. completeness), `enliterator_measures` | facet (its pre-v0.12 name!) |
| **Requests / authority control** | the suggestion review queue (propose → pressure → considerer → ratify) | — |

**Homonym hazards** (a blind rename WILL break the app):
- `stream` still legitimately means **HTTP/SSE streaming**: `conversation#stream`, `converse(stream:)`,
  `stream_raw`, `response.stream`. Never rename those. (`tend` takes `facet:`; `converse` takes `stream:`.)
- `context` (v0.13+, collection context) vs `context_cap` (LLM context-window cap in the staffing
  Policy) vs RSpec's `context` — unrelated concepts sharing a word.
- `.keys` is also the Hash method — any keys→terms work must be colon-targeted (`keys:`), never bare.

## Hard rules

1. **Byte-identical back-compat.** Every feature is additive and gated: with the new thing unused
   (no contract / nothing approved / no context), behavior must be byte-identical to the prior
   version and the full suite must stay green. This is the project's core discipline.
2. **The UI is 100% self-contained.** HSDL uses Sprockets; the dummy uses Propshaft. All CSS/JS
   inline in ERB/layout. NO `stylesheet_link_tag`/`javascript_include_tag` for engine assets, no
   files under `app/assets` referenced by views, no new gems/CDN/fonts for UI. (A violation 500s
   the host with `AssetNotPrecompiledError` — it happened.)
3. **No silent failures.** The Null LLM adapter must never no-op-succeed a real tend
   (`allow_null_llm` guard — the founding v0.5 lesson). Every early return logs why.
4. **Versions are commits + SPEC.md sections**, not gem bumps (gem stays 0.1.0). Each version:
   code + specs green + SPEC.md section + README touch + commit. Tags/`gh release create` on push.
5. **The About page is a living document** — SPEC v0.10's definition of done says revise it every
   version. It's both the demo surface and Jeremy's north-star doc.
6. **Push only on Jeremy's explicit word** — engine pushes, releases, and ALL HSDL-side
   commits/`bundle update` are gated. HSDL's Gemfile pins this repo's `main`.
7. **Migrations must be reversible** and applied to BOTH `spec/dummy` and HSDL dev
   (`cd spec/dummy && bin/rails db:migrate`, then HSDL `bin/rails db:migrate`).

## Commands

```bash
bundle exec rspec                  # full suite from the ENGINE ROOT (running from spec/dummy finds 0 examples)
cd spec/dummy && bin/rails db:migrate   # apply engine migrations to the dummy
```

HSDL dev (the live integration check — UI at http://localhost:3055/enliterator/):
```bash
cd ../hsdl-ai
set -a; source ~/.hsdl-rails.env; set +a   # rails runner needs env sourced inline
bin/restart web        # REQUIRED after engine Ruby changes (gem code doesn't hot-reload; views do)
bin/rails enliterator:tend_theses YEARS=5 FACET=significance LIMIT=5
bin/rails enliterator:consider     # run the considerer over open vocabulary requests
bin/rails enliterator:status       # per-facet tending health rollup
```

Ruby in shell: always `bin/rails runner - <<'RUBY' … RUBY` (heredoc, single-quoted delimiter).

## Architecture in one breath

`Tendable` (host concern) → `tend!(facet:)` → `Tending::Visitor` resolves tier from the
`Staffing::Policy` (facets are roles, LiteLLM aliases are capability tiers, bounded escalation
ladder, verify floor) → adapter `#tend` with the facet's `Vocabulary` threaded into schema+prompt →
claims reconciled against live claims (the chokepoint is `live_claim_for`) → off-vocabulary
observations become `Suggestion`s → pressure accumulates in `ProposedTerm` → the `Considerer`
auto-applies safe verdicts, holds approvals → approved terms go **live** in the effective
vocabulary and re-proposals of resolved terms are **suppressed** (the loop converges).
Surfaces: Status (finding aid) · Chat (reference interview, SSE; scope banner shows the active
context) · Requests (authority control) · Contexts (the tree) · Heartbeat (trigger + watch a
cycle live) · About · Settings. v0.13 contexts rule: NULL context IS root.

## Current state & direction

- Remote: github.com/jeremedia/enliterator-engine, **released through v0.41** (tags + GitHub
  releases v0.18–v0.41; engine `main` @ `577a0f6` = the v0.31–v0.41 SPEC/About doc catch-up on top
  of the v0.41 code at `0d80e43`; HSDL `enliterator-integration` pinned at `271f584`). The early
  version history:
  v0.19 = the component standard (tokens + shared components in
  the layout style block, ctx-switch left beside what it scopes, Requests queue as per-term
  cards). v0.20 = the prepared finding aid: Status/Heartbeat previews read the last ledger
  row's `planned` jsonb via `Heartbeat::PreparedPlan` (live census only on a host with zero
  cycles; `open!` re-plans at beat) — the pages went 18s/13s → sub-second; frontier_fetch's
  failure-backoff is a hashed `NOT IN` SubPlan (correlated NOT EXISTS + the uuid→text cast's
  missing stats made PG nested-loop 314K probes — 8,980ms → 384ms, EXPLAIN-verified);
  Synopsis.build + Condition.report serve from Rails.cache keyed by latest heartbeat id +
  5-min TTL (Solid Cache in HSDL dev; null store recomputes — and the memory-store spec caught
  Report.summary returning an unmarshalable default-proc hash, fixed at source);
  ProposedTerm.refresh!'s per-key resurged COUNT batched to one JOIN. v0.21 = the Atlas
  (ninth surface, /enliterator/atlas): the claim store drawn as a labeled property graph —
  records as nodes, entity-bearing claims as typed edges (the vocabulary IS the legend),
  every edge carrying tier/conf/asserted-at/audit-verdict, time slider replays the collection
  learning; `Enliterator::Atlas` is host-generic (adaptive entity-bearing keys; resolution via
  IDENTIFIER-pattern claim values + titles — attribute claims must never enter the index or
  they self-resolve into silence, spec-pinned); inline vanilla-JS canvas force sim (no D3 —
  hard rule 2); `rake enliterator:atlas FILE=` exports ONE self-contained HTML (the shareable
  artifact for AWS/HSDL staff). **448 examples.**
  **The pacemaker is LIVE and VERIFIED**: launchd `app.domt.hsdl-ai-enliterator-heartbeat` beats
  HSDL nightly; first unattended cycle (2026-06-10) ran clean — 53/53, 173K/200K actual tokens,
  all phases on the ledger, zero warnings. Gotcha: launchd fires on the SYSTEM clock (Central,
  -0500) while the app zone is Pacific — "3:30" in the plist is 1:30 PT on the ledger; the 2 AM
  sync rides the same clock so ordering holds. Supervised week of morning ledgers in progress
  (log: ~/Library/Logs/hsdl-ai-enliterator-heartbeat.log; the cycle's narrative is in
  development.log — stdout gets only boot warnings). Morning review day 1 caught + fixed the
  audit sampler's alphabetical tie-break starving the last cells at n < cell-count.
- HSDL dev: the federation is seated as a context tree (chds-theses 1,327 / crs-reports 35,020 /
  executive-orders 1,026 / election-security 82); divergence validated (EO supersession graph,
  CRS issue_for_congress); the `keywords` term ratified live as the convergence proof. HSDL-side
  work is committed locally on `enliterator-integration` (UNPUSHED — gated).
- **Deadline shaping the build**: FEDLINK talk (Library of Congress) **2026-07-14** — the audience
  is federal librarians; speak their language (authority control, finding aids, literary warrant).
- **v0.15 — the EVENT-DRIVEN heartbeat** (built from v0.14's gate verdict; SPEC.md v0.15):
  `Heartbeat.plan` (pure read: change envelope source_change→neighborhood→vocabulary at 20% share,
  frontier gets the rest + spillover, stale_after demoted to a leftover sweep, horizon math) and
  `Heartbeat.beat!` (the row IS the overlap lock; sync mode enforces the budget on ACTUAL tokens;
  considerer pass closes each cycle; visits stamped heartbeat_id+reason). Rake
  `enliterator:heartbeat` (PLAN=1/BUDGET=/ENQUEUE=1/FORCE=1/SKIP_CONSIDER=1, sync default).
  Triggers anchored to lane MAX(started_at) — NOT finished_at/last_tended_at (mid-visit race;
  also `last_tended_at(context: nil)` is UNFILTERED, not root-scoped — a named trap). Neighborhood
  is context-lanes-only, suppressed while the lane's frontier is non-empty, cooled down per record.
  Status preview is adoption-gated (no ledger rows ⇒ byte-identical page).
- **v0.16 — the pulse monitor** (SPEC.md v0.16): `/heartbeat` page — plan + Beat-now trigger
  (budget clamped to config; `Heartbeat.open!` holds a pg advisory lock around check→plan→create
  so two tabs can't double-spend) + a live monitor polling `/heartbeat/pulse/:id` (items-based
  progress from distinct visit tuples, visit ticker, stall banner with force-form, resilient
  poll loop). Execution = `execute_async!` (named thread under executor.wrap, NOT ActiveJob —
  dead worker = silent no-op; accepted: dev reload waits while a cycle runs). Also: the chat
  scope banner (the context cookie was invisible on /chat — Jeremy hit it as a user).
- **v0.17 — Condition** (SPEC.md v0.17): digital preservation's ladder as host probes
  (`Condition.register`, `gates_tending:` marks the can-the-engine-read-it probe; NO short-circuit
  — surrogates count); rollup bands 1.0/0.5/0.0; signature piles; untendable gate on ALL FIVE
  planner queries (the url_status-flip → source_change loop is closed) + per-item execution gate;
  survey phase first in execute! (time-boxed) + `rake enliterator:survey` (initial inventory);
  Conservator (Considerer pattern, positional ids, remediation-as-ground-truth, delta gate) →
  `enliterator_treatments` (no status machine — resolution is measured); conservation report on
  Status. `Measures.register` raises on the condition namespace. `Tendable#retract_claim!`.
- **v0.18 — the Audit** (SPEC.md v0.18): `Audit.sample` (stratified facet×tier over live,
  engine-derived, unlocked, unaudited claims), `Audit::Examiner` (full-text grounded — snippet
  bounds yield false 'unsupported'; blind; unverifiable verdict; digest stamped),
  `Audit.accuracy` (PROCESS rate — audits never age out, re-tending can't launder it; human
  verdict outranks examiner), `anchor_agreement` (binary, min n=10, overruled-supported line),
  `audit_phase!` (default 0 = OFF; adoption = setting heartbeat_audit_sample), `rake
  enliterator:audit N=`, `/review` (confirm/overrule/correct → `Tendable#correct_claim!`, NOT
  assert_claim! — locked human supersession; `Claim::AlreadySuperseded` race guard), Status
  accuracy panel.
- **NEXT** (2026-06-14): SPEC / About / README / this file all caught up through v0.41 —
  version-log doc-debt cleared. Live threads: **v2 conversation-tending** (make `Chat::Turn` a
  Tendable + conversation-quality facets — grounded / answered / register-held / tool-efficient —
  the payoff v0.39 retention was built for); **Plan B** (the public accountless desk: sessionless,
  link-token, rate-limited, per-surface affordance scrub, leashed web tool); the **Bedrock
  campaign** (campaign tier = bedrock-sonnet on the grant; blocked on an NPS IAM key — the ~9h SSO
  ceiling caps multi-day autonomy); the **auth wrap on /enliterator (incl. /mcp, /desks,
  /conversations) before staging**. Deadline: FEDLINK 2026-07-14. Next enliteration after HSDL =
  currently the Curation Engine Collections project (the method skill's Visit 2 — shape NOT yet
  examined). UI rule still in force (v0.19): new pages compose from the layout's tokens/components;
  page `<style>` is page-specific layout only.
- **How updates reach the engine (answered 2026-06-10)**: source_change = `updated_at` vs lane
  anchor — the legacy→dev sync's row rewrites ARE the signal, zero integration. ASSOCIATED
  tables (vocabulary_term_relations, marc_subjects) are INVISIBLE (no touch:true, raw-SQL
  reconciles) and that is correct today because `to_enliterator_text` reads only
  title/description/summary_data/docling_markdown. WATCH ITEM: if catalog metadata ever joins
  the tending input, wire a signal (sync-rake touch, touch:true, or point
  `heartbeat_source_changed` at a digest covering associations).
- **v0.41.1 — graceful bedrock UNAVAILABILITY** (resilience hotfix; committed locally, UNPUSHED —
  gated): ALL enliteration runs on the $10k Bedrock credit — NO funds for any other model, so NO
  fallback (Jeremy, emphatically: do NOT route governance/audit to `quality`/gpt — everything stays
  bedrock). The pipeline must SURVIVE bedrock's transient failures, not route around them. Two modes
  poisoned the nightly cycle: (1) expired SSO token — renewed token lives ~9h but the beat is 01:30,
  so an unattended beat ALWAYS meets an expired token until the NPS-IAM key (non-expiring creds)
  lands (id=55); (2) a bedrock TIMEOUT mid-cycle even on a valid token — the considerer (and
  conservator + audit examiner) all run on bedrock-sonnet (they default to `ladder.last`, and HSDL's
  ladder = `[cheap, quality, bedrock-sonnet]`), and id=54/id=56 timed out on the considerer (id=56:
  on the 4th of ~5 scopes; old code saved only at loop end, so the 3 completed scopes were LOST).
  Root cause (2026-06-17): the heartbeat had NO transient-failure concept — recognition lived only in
  `Chat::ErrorReport` (chat surface), never consulted by the pacemaker — so a transient failure either
  tripped `EARLY_FAILURE_LIMIT` (id=51, tokens=0) or became the cycle's terminal `error`, skipping
  considerer/conserve/audit and exiting 1. Fix: `Bedrock.unavailable?(error)` =
  `auth_lapsed?` (AWS-expiry signature ANDed with `/bedrock/i` — only-on-bedrock; false for throttling
  + non-bedrock SSO) ∨ `TRANSIENT_RX` (timeout/Net::ReadTimeout/ECONNREFUSED/503/502 — tier-agnostic,
  safe to retry anywhere); SDK-free (engine has no aws-sdk dep). `work_items!` DEFERS a transient
  failure (stays on frontier, no Visit, lazy `deferred` tally, NOT counted toward EARLY_FAILURE);
  `consider!` holds the failing scope per-scope (the reached scopes' `update!` still runs → preserved);
  `execute!` top-level net = clean finish (no error, exit 0) backstop. Real faults (bad request,
  model-not-found, bugs) STAY fatal. No-deferral cycles byte-identical. Engine half only — the
  9h-vs-01:30 gap closes only with the IAM key; until then, deferred work drains on any valid-token
  beat (trigger a daytime beat after re-auth). Live on tonight's launchd beat automatically (fresh
  rake loads the local override; no push/restart for the pacemaker). **735 green** (+18). SPEC
  §v0.41.1 / About colophon / README heartbeat touched. NOTE rejected approach: moving governance off
  bedrock to a stable tier — there are no funds for non-bedrock models, so resilience-on-bedrock is
  the only path.
- **v0.41 — reset-to-seed**: `DesksController#reset` records a NEW version copying
  `desk.system_prompt` (append-only — the reset is itself auditable, never a delete); `/desks`
  computes `overridden = effective != seed` and shows the Reset button (inline `confirm`, no UJS —
  rule 2) ONLY when overridden, with a "using the registered seed / curator override active" status
  line. Gated with the rest of `/desks` by `config.chat_persona_editing`. **717 green.**
- **v0.40 — the `enliterating-a-collection` SKILL** (the METHOD shipped in the gem at
  `skills/enliterating-a-collection/SKILL.md`): build-IN-to-LIS stance; the method (derive text
  first — the foundation for non-text collections; facets-as-roles/tiers-as-capability; vocabulary
  self-governance; condition before spend; heartbeat on the changed frontier; measured audit; the
  reference-desk pattern); a common-mistakes table from a RED baseline; the ethic. Written
  writing-skills-TDD (RED museum-photo baseline [generic "AI enrichment", invented vocab, tended
  unreadable records] → GREEN [TGM/TGN/LCNAF-grounded, legibility-gated, audited]); encoded as a
  FIRST DRAFT with a Tending log (Visit 0 HSDL, Visit 1 photo archive). Docs only — no runtime change.
- **v0.39 — chat retention** (`config.chat_retention`, default off): `Chat::Conversation` +
  `Chat::Turn` (events-jsonb-as-artifact; tendable-ready: answer/desk_name/persona_id/elapsed_ms/
  budget_hit). Capture = TEE the SSE sink (`ConversationController#stream` wraps the sink when on) →
  `Chat::Recorder.record` (derives answer/desk/persona/budget from the event array; tolerates
  symbol+string keys; NEVER raises — rescues + logs, rule 3). Re-stream replay: `GET /chat/replay/:id`
  re-emits stored events as SSE (`replay_user`/`replay_end` frames; inter-token delay skipped in
  test) so the federated client renders a replay IDENTICALLY to live, zero model spend.
  `/conversations` browse/label/delete (inline `onclick` confirm — NOT data-confirm; no UJS).
  `Chat::Eval` records through the same path. THE EVENT ARRAY IS THE ARTIFACT (transport = record =
  replay source = v2 tending input). Two reversible migrations (conversations + turns), applied to
  dummy + HSDL. **715 green.**
- **v0.38 — per-agent step_cap + no-browser eval**: `Chat::Agent#step_cap` (nilable); Loop uses
  `effective_step_cap = @agent.step_cap || @step_cap` (HSDL CHDS = 10 fixes intermittent "step
  budget" non-answers). `Chat::Eval.ask(question, context:, record:, **loop_opts)` → `Result`
  (answer/tools/handoffs/followups/elapsed_s/budget_hit/events) drives the REAL Loop minus
  transport; `rake enliterator:ask` = the CLI front door (scriptable; exposes the run-to-run
  variance the browser hides — it found the step-budget bug).
- **v0.37 — persona editing** (`config.chat_persona_editing`, default off, controller 404s when
  off): `Chat::Persona` append-only versioned store (`enliterator_chat_personas`);
  `record`/`effective`/`history`. Loop `persona_for(agent) = Persona.effective(agent.name) ||
  agent.system_prompt` → `Chat.compose_system`, live next turn ("code seeds, the store governs").
  `/desks` editor: editable persona; READ-ONLY register + org chart (tier/tools/routes code-owned);
  composed preview (exactly what the Loop sends); history + rollback. `config.chat_editor` =
  callable(request)→editor seam (rescued, auth-agnostic). SAFE because the LOOP not the persona
  enforces grounding/allow-list/provenance. Reversible migration applied to dummy + HSDL.
- **v0.36 — the reference register** (`config.chat_register`): `Chat::Register::DEFAULT` = frozen
  institution-formal LIS voice (code-owned — the institution's voice, not a knob).
  `Chat.compose_system` = `[register_text, persona_text, (Followups::DIRECTIVE if
  chat_followups)].compact.join` — the Loop calls it at run init AND on every handoff reset
  (specialists inherit the register). This is the seam v0.37's editable persona plugs into.
  Patron-voiced follow-up directive. **663 green.**
- **v0.35 — Stage C: agent-reasoned follow-ups** (`config.chat_followups`, default off):
  `Chat::Followups` (SENTINEL `%%FOLLOWUPS%%`, MAX 3, DIRECTIVE, `parse` with a `take_while`
  truncation guard). Loop appends the directive + emits a `:followups` event after the final answer;
  client renders clickable question buttons; `proseOf` STRIPS the sentinel+tail from streamed prose
  (golden-guarded). The v0.29 DOM-scrape follow-up scaffold is RETIRED. Controller logs click-through
  (gated, truncated query) — instrumented ("the experiment is the point"). OFF byte-identical.
- **v0.34 — follow the stream**: federated auto-scroll that YIELDS to manual scroll and resumes at
  bottom; Sources rail collapsed into a closed `<details>`. Client refactor extracted `followStream`
  (the error-card path calls it → test factory injects a noop). Off-view byte-identical.
- **v0.33 — streaming federation answers**: `Gateway#converse_with_tools` stream path now ASSEMBLES
  tool-call deltas (`extract_tool_call_deltas`: concat `arguments` fragments by index; builds
  `tool_calls` + `assistant_message` in the SAME shapes as the non-stream path). Loop streams with
  the load-bearing `emit(:token,…) unless streamed` guard — a non-streaming adapter / the test
  `ScriptedLLM` (ignores the block) keeps `streamed` false → full-text emit → every existing loop
  spec green unchanged. No new SSE event (reuses `:token`); federation-path only; budgets between
  rounds don't chop a streaming answer.
- **v0.32 — clickable navigation (Stage A)**: inline ask-links from consulted records (click a
  record → ask the desk about it, in place; rides the v0.29 citation metadata). Bug fix: the
  `search` widget read the wrong key and rendered empty — corrected to `:records` (a real silent
  failure closed; it's what gives the ask-links anything to point at).
- **v0.31 — the reading room quiets**: welcoming empty state + receding chat chrome
  (federation-gated); live "Working… Ns" thinking timer (client wall-clock); empty work-trace
  "view" suppressed. Pure surface; off-view byte-identical.
- **v0.30 — actionable errors at the desk**: `config.error_detail` (3-state nil/true/false,
  default nil = auto via the one guarded `Rails.env.development?` touch, host-overridable);
  `Chat::ErrorReport.build` = the SOLE `:error` constructor — `{message:}` ALWAYS from a static
  literal (never `error.message` — a secret can't route around the gate); `detail`/`where`/`hint`
  added only past `return h unless detail` (keys-canary spec). Loop + controller emit a structured
  `:error` (covers federated + single-shot); resolved SERVER-side only (no `?error_detail=1`).
  Client `renderErrorCard` is textContent-safe; `els.errored` survives the turn-finish flush.
  Prod/off payload byte-identical.
- **v0.29 — the Reference Desk, made legible (the agentic surface, elevated)**: a pure
  SURFACE elevation of v0.28's agentic chat + an engine-wide design-language pass. NO loop
  change, NO new SSE event — the same governed loop, finally shown. (1) Global design
  language in `app/views/layouts/enliterator/application.html.erb`: system-serif display
  headings via `--font-display` (applied ONLY to h1/h2/.section-head), `--fs-display` scale,
  depth tokens `--shadow`/`--shadow-pop`, `--accent-dark` hover token, unified focus/hover,
  `prefers-reduced-motion` guard, and the About stat-strip promoted to a shared `.stats-strip`
  component (rippled to Status/Catalog/Atlas/About/Chat). (2) The **`enl-*` widget CSS system**
  lives in that SAME layout file — card chassis + 8 structured variants, the `.enl-trace*`
  timeline, `.enl-handoff` divider, `.enl-cite`/`.enl-cite__pop`/`.enl-sources` citation
  furniture. NAMESPACED so it selects nothing on a federation-OFF page (the CSS is inert, not
  absent — the gate withholds the MARKUP). (3) Four new widget renderers in
  `app/services/enliterator/chat/widget.rb`: `collection_overview` (stat-strip),
  `browse_subjects` (heading index), `vocabulary` (facet rows), `recent_activity` (diary);
  JSON fallback collapsed into `<details>`. (4) Agentic turn model in
  `app/views/enliterator/conversation/index.html.erb` (federation-gated): turn = live
  work-trace (per-tool spinner→✓, human labels, widget in a `<details>`) → answer (lazy, lands
  under the trace) → sources rail; handoff = visible divider + NON-destructive
  `#enl-scope-banner` update. (5) Shared `mdToHtml` extended (blockquotes, HRs, GitHub pipe
  tables, nested lists) — frozen by `spec/javascript/md_golden.test.js` (pre-existing output
  byte-identical; negative guards). (6) Composer: autosize, Enter-submits/Shift+Enter, typing
  indicator, dynamic follow-ups from records consulted. (7) Citations: `widget.rb` data attrs
  + view client-correlates → numbered sources rail (→ `/enliterator/status/<Type>/<id>`) + inline
  `.enl-cite` chips (hover popover, click record); safety frozen by
  `spec/javascript/cite_logic.test.js` (text-node-only, never inside an `<a>`). RULES THAT BITE:
  100% inline vanilla (no CDN/npm/gem/asset-pipeline/web-font — serif is a SYSTEM stack);
  federation OFF emits NO `enl-*` DOM and NONE of the federated JS (`handleFrameFederated`,
  `submitQuestionFederated`, `finishTurnFederated`, `annotateCites`, `makeCiteChip`,
  `buildCitePop`, `wrapFirstMatch`) — single-shot contract (`token`/`provenance`/`done`)
  byte-identical, now CODIFIED by
  `spec/requests/enliterator/conversation_federation_spec.rb` (off-view body asserts none of
  `enl-trace`/`enl-result`/`enl-cite`/`enl-sources`/`enl-handoff` + no federated fn names).
  DEFERRED (honest): citations are client-correlated today — a structured `sources` SSE event
  + `DocMetum`→human type-label map is the future; `tool_call_start` payload enrichment also
  deferred. NOT-in-engine: a decisiveness directive on the CHDS specialist PROMPT (HSDL-side,
  uncommitted) — deployment grounding, not an engine change. ≥606 examples.
- **v0.28 — the Reference Desk (Plan A: the agentic core)**: Plan A built under
  `Enliterator::Chat` — `Gateway#converse_with_tools` (optional-multi-tool adapter
  primitive; `ToolTurn` return; Null/Bedrock raise `NotImplementedError` — loud fail on
  misconfiguration); `Chat::Widget` (pure-function tool renderers: record_entry /
  provenance / trajectory / accuracy / search / subject_search / quote / connections +
  JSON fallback; class-names only; all tool data HTML-escaped — hard rule 2); `Chat::Agent`
  + registry (`Chat.register`, `Chat.for_context` fallback to Frontdesk; fail-fast tier
  validation at registration; duplicate-Frontdesk guard); `Chat::Loop` — THE ENFORCEMENT
  BOUNDARY (the loop, not the model, enforces): route_to intercepted FIRST (switch agent,
  emit handoff, NEVER dispatch); allow-list checked BEFORE `Mcp.dispatch` (read-only
  enforcement — injected write instructions are blocked by name); grounding injected only
  for context-bearing tools the model left unscoped (model scope honored — grounded, not
  walled); step cap + per-turn wall-clock budget; tool failure or gateway raise → VISIBLE
  terminal event (rule 3). On handoff: re-resolves LLM + switches system prompt per new
  agent's tier. `Audit.accuracy` cached (last-write + count key — NOT heartbeat id).
  Federation-gated transport: `ConversationController#stream` drives the loop when
  `config.chat_federation` ON; 5 new SSE events (`tool_call_start` / `tool_call_result` /
  `tool_call_error` / `handoff` + existing `token`/`provenance`/`done`); AG-UI semantics,
  not its casing. RULES THAT BITE: `config.chat_federation` is OFF by default — suite is
  byte-identical to v0.27 when unused; agents must resolve to a `converse_with_tools`
  gateway tier or registration fails; the off-path view is byte-identical (literal diff
  verified). Plan B (public accountless desk: sessionless controller, link token, rate
  limit, per-surface affordance scrub, leashed web tool) is the HORIZON, not yet built.
  572 examples.
- **v0.27 — the Brief**: `Enliterator::Brief.report(since:)` — the time-windowed activity
  digest ("how did last night's tending go?"): heartbeats compacted, visits by
  facet/tier/reason, failures WITH their Visit.error, deep-read part visits rolled up to
  parent records, governance motion (suggestions by status, ProposedTerm by
  recommended_decision — it has NO status column, audits by source×verdict). Surfaced as
  `rake enliterator:brief HOURS=` and MCP tool `recent_activity` (the 14th — clamps hours
  1–168, never errors on range). Breadth over a window; `Report.summary` /
  `enliterator:status` stays the per-facet DEPTH instrument — the Brief duplicates none
  of it. Pure read. 537 examples.
- **v0.26 — the MCP surface** (`POST /enliterator/mcp`): the protocol minimum INLINE
  (JSON-RPC 2.0, tools only, no gem, no SSE, stateless; `claude mcp add --transport http
  enliterator http://localhost:3055/enliterator/mcp`). 13 tools = projections over cached
  services: collection_overview/vocabulary/search/browse_subjects/subject_search/
  record_entry/connections/trajectory/provenance/quote/accuracy + governed writes
  propose_term (suggestions queue) + flag_claim (agent Audit → /review queue). RULES THAT
  BITE: Audit SOURCES gained "agent" and the v0.18 instrument scopes to
  `Audit.instrument` (examiner+human) in FOUR sites — effective_verdicts, audit_pairs,
  sampler candidate_scope, Atlas verdict precedence — spec-pinned that an agent flag
  changes NO accuracy number and doesn't remove a claim from the sampling pool. McpController
  needs skip_forgery_protection. quote locates spans LEXICALLY (exact → densest token
  cluster → located:false head). Tool payloads bounded + self-describing (`next:` hints).
  527 examples.
- **v0.25 — analytical cataloging (the deep read)**: `Enliterator::Part` (sections as
  first-class tendables — Tendable polymorphism gives them the WHOLE loop free) +
  `Tending::Reading` (section → per-part analysis reads → kind "part" embeddings →
  synthesis re-tends work facets from `Part.notebook_for`). RULES THAT BITE: (1) engine
  models never register (`register_tendable` skips `Enliterator::*`) AND the visit-log
  union reads `Visit.host_tendable_types` — without BOTH, tended parts resurrect into
  planner root lanes/corpus census/survey; (2) `facet ..., scheduled: false` keeps a
  declared facet out of planner lanes (without it the pacemaker deep-reads unsupervised —
  context declarations FEED lanes); (3) drill-down allowlists use
  `Enliterator.tendable_type?` (hosts ∪ Part). Synthesis is NOTEBOOK-grounded (host's
  to_enliterator_text returns notebook for summary/significance/connections once notes
  exist — HSDL's kwarg was `stream:` since v0.4, DEAD since the v0.12 rename, fixed to
  `facet:`). Verified live: 26-part thesis read whole, 208 analytical claims, real
  cited_works/index_terms, significance deepened (supersession visible), summary honestly
  NOOP'd (abstract was already faithful). Pilot rake `enliterator:deep_read_pilot` (HSDL)
  + Trajectory::Judge verdict gates v0.26 heartbeat integration + the Bedrock campaign.
  analysis facet at QUALITY tier (gemma's 8K ctx can't hold whole sections). 506 examples.
- **v0.24 — the Catalog** (tenth surface, /enliterator/catalog): browse + search the
  enliterated holdings. Grid/search walk the embedding spine (`Embedding.in_context` —
  Conversation's pool, EXTRACTED; `ContextMembership.member_exists` is the generalized EXISTS
  builder); subject browse walks `Claim.understanding` (also extracted — Atlas refactored onto
  it) intersected with membership (cumulative claim reads would leak non-members into a scoped
  browse). LOAD-BEARING RULE: headings are byte-exact stored values, extraction admits ONLY
  the shapes jsonb containment (`value @> to_jsonb(term)`) can find again (string scalar,
  string array element — no hash digging, no strip, no numbers); counts are distinct RECORDS;
  spec-pinned congruence heading-count == click-through total. Identifier keys excluded by
  NAME (IDENTIFIER_KEY_RX — control numbers are access points, not subjects). Accession-order
  grid (id DESC — last-visit ordering would be a census), cached overview (v0.20 idiom),
  heading tally capped 50K/key ("≥"), ANN search = one honest page, degraded embedder names
  itself + falls back to browse. New claims index `[key, context_id]` (nothing led on key;
  Synopsis.key_summary rides it too). `/catalog/wander` = random record. 489 examples.
- **v0.23 — every cycle ends on the ledger**: heartbeat rows pulse liveness + phase
  (`pulse_at`/`phase`, stamped per phase AND per LLM-loop iteration); `Heartbeat.reap_orphans!`
  (run by open! and the monitor page) stamps process-death orphans — finished_at = last sign
  of life, death phase named, executed RECONSTRUCTED from visits; zombie threads of reaped
  rows raise `StoodDown` at their next loop check (the phase rescues re-raise it explicitly —
  don't let a new rescue swallow it); gateway+embedder clients are bounded
  (`gateway_timeout` 180s / `gateway_max_retries` 1 — the gem default was 600s×retries).
  Restarting the dev server mid-cycle is now SELF-HEALING (the row is reaped within 15 min) —
  but still avoid it during a supervised run you care about. Ticker times come as app-zone
  `at_label` strings (the Mac's system zone is Central; never let JS toLocale* render times).
- **The staging deploy checklist (v0.22 — gate EVERY HSDL staging/prod deploy on this)**:
  (1) PUSH THE ENGINE FIRST — HSDL's initializer sets v0.18+ config; bundling v0.17 from
  GitHub crashes at boot, and engine migrations load from the gem's paths; (2) wrap
  `/enliterator` + confirm `/maintenance_tasks` auth; (3) server env needs
  ENLITERATOR_LLM_KEY; (4) the pacemaker is per-host adoption (launchd is Mac-only);
  (5) seed data: dev `enliterator:export FILE=` → scp → target import (HSDL
  `Maintenance::ImportEnliterationTask`, or `enliterator:import FILE= [FORCE=1]`). The
  condition register deliberately stays home — run `enliterator:survey` on the target.
- Known open gaps: no claim-accuracy golden set (cheap-tier conf=1.0 unexamined); `/enliterator`
  mount is auth-less (dev only — wrap in CHDS Pulse auth before staging); considerer LLM tokens
  have no usage surface (ledger records outcomes only). Trajectory caveat: clean A/B isolation
  needs context-facet-only comparison (root facets use corpus-wide neighbors).
- Deferred by design: SKOS/BT/NT syndetic structure, LRM/WEMI, the cross-record flywheel,
  per-scope tended-counts on inherited facets, genre-intrinsic→root claim promotion, per-visit
  source digests (the exact source-change signal).

## Jeremy's standing directives for this project

- **Build IN to library science, don't reinvent it** ("my limits are not your limits") — before
  building custom, check whether LIS already has the standard (it usually does).
- Greatness or external force — no quick fixes that leave rough seams; the craft must hold up
  per-system.
- He reads the About page to understand what we're building. Keep it true.
