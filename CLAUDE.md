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

- Remote: github.com/jeremedia/enliterator-engine, **released through v0.23** (pushed 2026-06-10/11;
  tags + GitHub releases v0.18–v0.22; v0.23 pushed via another of Jeremy's sessions, which also
  pinned HSDL's Gemfile to it — HSDL commit 43943ba — and cut HSDL Release v1.42.0; check whether
  a v0.23 tag/release exists before assuming). The version history:
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
- **NEXT**: read morning ledgers for the supervised week (2026-06-11 morning's cycle is the
  FIRST with v0.23 pulse stamping — expect phase nil + pulse_at ≈ finished_at; also the first
  audit allocation since the sampler fix should finally include significance/*); accumulate
  audit cells toward n≈30; human-anchor sessions on /review (~18+ approvals waiting on
  /requests from cycles #12/#45); vocabulary trigger still UNMEASURED. Then: the frontier
  conversation (bound root lanes vs raise budget) and the auth wrap before staging (engine-push
  prerequisite now CLEARED; FEDLINK 2026-07-14). UI rule going forward (v0.19): new pages
  compose from the layout's tokens/components; page `<style>` is page-specific layout only.
- **How updates reach the engine (answered 2026-06-10)**: source_change = `updated_at` vs lane
  anchor — the legacy→dev sync's row rewrites ARE the signal, zero integration. ASSOCIATED
  tables (vocabulary_term_relations, marc_subjects) are INVISIBLE (no touch:true, raw-SQL
  reconciles) and that is correct today because `to_enliterator_text` reads only
  title/description/summary_data/docling_markdown. WATCH ITEM: if catalog metadata ever joins
  the tending input, wire a signal (sync-rake touch, touch:true, or point
  `heartbeat_source_changed` at a digest covering associations).
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
