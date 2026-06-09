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
Surfaces: Status (finding aid) · Chat (reference interview, SSE) · Requests (authority control) ·
About · Settings. v0.13 (in plan) adds nested **Contexts**: ancestry tree, context-scoped
claims/visits, per-context facets, membership-scoped neighbors — rule: NULL context IS root.

## Current state & direction

- Remote: github.com/jeremedia/enliterator-engine, released through **v0.14**.
- HSDL dev: the federation is seated as a context tree (chds-theses 1,327 / crs-reports 35,020 /
  executive-orders 1,026 / election-security 82); divergence validated (EO supersession graph,
  CRS issue_for_congress); the `keywords` term ratified live as the convergence proof. HSDL-side
  work is committed locally on `enliterator-integration` (UNPUSHED — gated).
- **Deadline shaping the build**: FEDLINK talk (Library of Congress) **2026-07-14** — the audience
  is federal librarians; speak their language (authority control, finding aids, literary warrant).
- **v0.14 ran the compounding experiment** (SPEC.md "v0.14 findings"): zero churn (re-visits safe);
  no free compounding from re-reading (unchanged surroundings ⇒ NOOP); deepening tracks
  surroundings-change; first attention dwarfs re-attention (158 claims pass 1 vs 13 after).
- **NEXT: v0.15 — the EVENT-DRIVEN heartbeat** (the experiment's gate verdict). Not wall-clock:
  (1) frontier-first — work the untended members of each context (35K CRS waiting);
  (2) re-tend ON CHANGE — a record's context-mates got tended / a vocabulary approval landed on
  its facet / the record's text changed; (3) `stale_after` demoted to a slow safety-net sweep;
  (4) a per-cycle SPEND CAP and the trajectory surface as the standing watch instrument.
  All trigger signals are already derivable from existing tables (Visits per context since t,
  Suggestion status transitions, record updated_at vs last_tended_at).
- Known open gaps: no claim-accuracy golden set; `/enliterator` mount is auth-less (dev only —
  wrap in CHDS Pulse auth before staging). Trajectory caveat: clean A/B isolation needs
  context-facet-only comparison (root facets use corpus-wide neighbors).
- Deferred by design: SKOS/BT/NT syndetic structure, LRM/WEMI, the cross-record flywheel,
  per-scope tended-counts on inherited facets, genre-intrinsic→root claim promotion.

## Jeremy's standing directives for this project

- **Build IN to library science, don't reinvent it** ("my limits are not your limits") — before
  building custom, check whether LIS already has the standard (it usually does).
- Greatness or external force — no quick fixes that leave rough seams; the craft must hold up
  per-system.
- He reads the About page to understand what we're building. Keep it true.
