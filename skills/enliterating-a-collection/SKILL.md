---
name: enliterating-a-collection
description: Use when applying AI to understand or describe a collection of records — including when the ask is phrased as "AI enrichment," "metadata generation," "enrich the archive/catalog with an LLM," "auto-tagging," a "cataloging" or "data enrichment pipeline," or "run a model over the collection." Also when explicitly conferring literacy with the Enliterator engine: modeling a new host collection or context, designing its facets, staffing tiers, controlled vocabulary, conditions, or reference desks, or planning a tending campaign. The judgment layer for wielding the gem's machinery — and the corrective for the naive enrichment pipeline it replaces.
---

# Enliterating a Collection

The Enliterator gem ships the **machinery** (the tending loop, the claim store, the self-governing vocabulary, contexts, conditions, the heartbeat, the surfaces, the reference desk). This skill is the **method** — the judgment for pointing that machinery at a real collection. Without it, a capable engineer produces a plausible "AI enrichment pipeline" that misses what makes enliteration different: it throws embeddings and an LLM at the data, invents vocabulary from scratch, tends records it can't even read, and never measures whether it's right.

**Core principle: enliteration is library/information science, mechanized — not LLM enrichment.** The difference is grounding, governance, condition, and measured accuracy.

## This is a first draft — tend it through every use

This skill is itself an **enliterated artifact**. It confers a literacy (how to enliterate), so like every record in the engine, its understanding must **compound across visits**. It was harvested from the *first* enliteration (HSDL — a federation of homeland-security scholarship), so it is partial, HSDL-shaped, and certainly wrong in places for the next collection.

**The protocol — every use is a tending visit on this skill:**
1. **Read the record's history** (this skill) before acting.
2. As you work, **note where the method was silent, wrong, or HSDL-specific where it claimed to be general** (a museum's photo archive, a legal corpus, a codebase will each break assumptions here).
3. At the end, **reconcile**: add what generalizes, correct what was collection-specific, mark what's still uncertain. State which collection taught it (provenance).
4. **Seeds, not fossils** — encode the *reasoning*, not just the conclusion, so the next collection can derive the right call in a context this draft never imagined.

The skill that teaches compounding attention must itself receive it. If you finish an enliteration and didn't touch this skill, either it was perfect (unlikely) or you skipped the visit.

## The stance (do this first): build IN to library science — don't reinvent

Before defining a single facet or vocabulary term, ask: **does the field already have the standard?** It almost always does. "My limits are not your limits" — you (Claude) hold the LIS corpus; use it.

- Controlled vocabulary / **authority control** — **identify the standard for THIS collection's material; do not default to LCSH.** Text subjects → LCSH; graphic materials/photographs → the Thesaurus for Graphic Materials (TGM I subjects + TGM II genre/format) as PRIMARY, LCSH supplementary; art/architecture → Getty AAT; medicine → MeSH; places → Getty TGN; personal/corporate names → LCNAF. Adopt the real thesaurus as the seed vocabulary; never invent `subject_matter` from scratch. The discipline is "find the field's own authority," not "reach for LCSH."
- **Finding aids** (the Status surface IS one), **literary warrant** (let the collection's own language justify terms), **Ranganathan's facets** (the dimensions a record is read along), **SKOS** (term relations), **PROV-O** (provenance — the claim store already speaks this).
- Speak the field's terms in code, copy, and commits. The audience (e.g. federal librarians) will know if you reinvented their discipline badly.

## The method (in order)

1. **Understand the collection.** What is the record? What is the *natural unit* (a document, an artwork, a thesis, a code module — and is there a sub-unit worth reading on its own, like a thesis's sections → `Part`)? Is it one collection or a **federation** of sub-collections? What does a reader read each record *along*? Sparseness is signal — do not pre-normalize the holes away; the engine reasons about them.

2. **Seat the contexts (the federation tree).** Nested collections = `Context`. Root facets apply to every record; a context's facets tend *within it* (declaration location = tending scope); members inherit the root reading. NULL context IS root. Model contexts so the compounding loop compares within meaningful cohorts (a 1910s industrial photo and a 1970s portrait have different neighbor pools), not across the whole corpus.

3. **Design the facets** (the tending lanes — Ranganathan, NOT claim keys). A facet is a dimension a record is read along, with its own prompt/tier/cadence. Per-context. Choose facets that **compound** (e.g. summary, significance, connections). Mark facts that MUST exist as **required terms** (a thesis HAS an author; a confidently-empty `authored_by` is a miss, not a fact — required terms force escalation and block `verified`). Use `scheduled: false` for facets tended by deliberate invocation (deep reads), not the pacemaker.

4. **Design the staffing policy (the org chart).** Facets are **roles**; gateway aliases are **capability tiers** (`draft`/`quality`/`deep` — name the *capability level*, never the vendor or model, so the backend can change without a code change). Set the **escalation ladder** (low-confidence draft → higher tier), the **verify floor** (only the top tier — or a human — may mint `verified`), the embedding tier, and `escalation_threshold`. First pass cheap for coverage; reconcile dense neighbor clusters at quality.

   **Name the governance tier explicitly — never let it inherit `ladder.last`.** Six components (Considerer, Conservator, `Audit::Examiner`, Conversation, `Trajectory::Judge`, FirstImpression) fall back to the *top of the tending ladder* when unset, and **none of them writes a `Visit` row**. So every ladder edit silently re-models and re-prices governance, and the tending log — the surface you would naturally check — structurally cannot show it. A live collection ran its nightly considerer, conservator, and examiner on the most expensive available model for five weeks this way; the tending log said that model was dormant, and the tending log was right and useless. Set `considerer_tier` and `audit_tier` by name.

   **Pin the examiner hardest.** Audit accuracy is a *process rate* that never ages out — old verdicts stay in the numerator forever. Swap the examiner's model mid-series and you have silently mixed two instruments into one number. An instrument that changes whenever you tune the thing it measures is not an instrument. Change it deliberately, and record that you did.

   **Audition a reader; never take its confidence as evidence.** When a tier's backend changes, the tempting measure is the tending log's average confidence — and it is worthless, because confidence is self-reported. A model that rates itself 0.87 is more confident, not more right; and since confidence drives escalation, a more self-assured reader escalates *less*, so it looks cheaper too. Instead, have candidates read the same records and score every claim with **one blind, source-grounded examiner** that is never told which candidate produced it, on the same scale as your standing quality review. Write nothing while you do it — an experiment that deposits its candidates' opinions in the live claim store is contaminating the thing it is protecting.

   **Score precision AND recall, or you will select the quietest reader.** A supported-rate rewards saying less: two safe claims beat six useful ones. Pair it with a coverage measure over **required terms** — the one place the collection knows what *should* have been produced — and count a blank value as a miss. Choose the audition facet with the same care: a generative facet like *summary* is a ceiling where every competent reader scores perfectly and the test has no power. Audition on facets where readers actually fail.

   **Record the model that answered, not the alias you asked for.** An alias is a pointer the institution can repoint — to a cheaper model, a newer one, or another vendor entirely — with no change to your code and no visible event. If your provenance stores the alias, that repointing silently rewrites the attribution of every subsequent claim while the record keeps reading the same. Store both: the alias you routed by, and the resolved backend the response reports.

5. **Let the vocabulary govern itself.** Code terms seed it; off-vocabulary observations become `Suggestion`s → pressure accumulates in `ProposedTerm` → the **Considerer** auto-applies safe verdicts and holds approvals → ratify → the term goes **live** and re-proposals are **suppressed** (the loop converges). This is authority control, not "an archivist reviews a queue weekly."

6. **Condition: make the collection shelf-read itself — and gate tending on it.** Register `Condition` probes (present → intact → legible). The **legibility probe `gates_tending`**: a title-only catalog card or an un-transcribed scan is *untendable* until text arrives — do not spend tokens tending what the engine can't read. Run a survey to inventory condition first.

   **Non-text collections — derive text first (this is the FOUNDATION, not a footnote).** The engine tends TEXT (`to_enliterator_text`). For images/audio/video, "legible" means *derived text exists*: a **derive-text-first phase** (multimodal description, caption/verso OCR, transcription) runs BEFORE tending and produces the substrate the engine then reads. Give it its own condition probe (e.g. `described`) that `gates_tending`, its OWN accuracy measurement, and store the derived description as a first-class artifact (version it — re-derivation will improve). **The derived description is to a photograph what the abstract is to a thesis** — the entire compounding loop rests on its quality, so give it comparable care. (Open question being tended: whether some facets should tend the image+description jointly, not just the derived text — see the tending log.)

7. **Run it on the heartbeat (event-driven, bounded).** Frontier first (untended members — highest claims/dollar), re-tend on **change** (source / neighborhood / vocabulary), `stale_after` as a slow safety net. A per-cycle **token budget** the cycle cannot exceed. The pacemaker is a host scheduler (launchd/cron). Re-reading unchanged surroundings is pure NOOP spend — the triggers exist to avoid it.

   **Reconcile spend against the provider's bill, not your own telemetry.** A gateway in front of the model is a convenience, not an accounting system: some routes report `$0.00` locally while the provider bills normally, so your dashboards show a quiet collection and the invoice shows otherwise. Two months of nightly spend hid in exactly that gap on a live deployment. Whatever your budget enforcement reads, check it against the billing source on a real cadence — and know *which account* is being billed, because on institutional infrastructure that answer has consequences beyond cost.

8. **Measure accuracy — don't assert it.** The **Audit**: stratified sampling, a *blind, full-text-grounded* examiner, **process-rate** accuracy (audits never age out; re-tending can't launder a bad number), and a **human anchor** (the Review surface — confirm/overrule/correct). Accuracy is a standing measured number, not a one-time spot check.

9. **The surfaces are the finding aid, made plural.** Status (finding aid + health), Catalog (OPAC), Atlas (the claim graph — the vocabulary IS the legend), Reference Desk (the chat), Requests (authority-control queue), Heartbeat (the pulse), About (the living thesis doc — keep it true). Compose new UI from the layout's tokens/components; 100% inline (no CDN/gems/web-fonts — a Sprockets host 500s otherwise).

10. **Design the Reference Desk.** A **Frontdesk** triages and routes; **grounded-but-not-walled specialists** advise within a context but may reach siblings. The engine owns the **institutional register** (anti-chipper, collection-as-subject — `config.chat_register`); the host supplies domain + persona, curator-editable and versioned (`/desks`). The Loop, not the prompt, is the enforcement boundary — so personas are safe to edit.

## The build discipline (when extending the engine)

byte-identical back-compat (every feature additive + gated; suite green when unused) · 100% inline UI · no silent failures (every early return logs why) · build IN not TO · greatness or external force (no rough seams) · the process: **brainstorm → spec → plan → subagent-driven build → live-verify → memory**; versions = tagged commits. Prefer driving the desk via `Chat::Eval` / `enliterator:ask` (no browser) for evaluation.

## Common mistakes (from the baseline that lacked this skill)

| Mistake | The method instead |
|---|---|
| Throw embeddings + an LLM at it ("enrichment") | Ground in LIS: authority control, facets, finding aids, measured accuracy |
| Invent vocabulary from scratch (`subject_matter`) | Adopt the field's real thesaurus (LCSH/AAT/TGM/MeSH) as the seed |
| "Facets" = claim keys | Facets are tending lanes (dimensions read-along); claims are what a visit asserts |
| cheap → quality, no ladder | Escalation ladder + verify floor + required-terms-force-escalation |
| Human reviews a vocab queue weekly | The self-governing, converging suggestion→considerer→ratify loop |
| Tend every record | Legibility gates tending — never spend on what can't be read |
| "Self-sustaining after bootstrap" (vague) | The event-driven heartbeat: frontier + change-triggers + token budget |
| One-time verification gate | The standing Audit: blind examiner + process-rate accuracy + human anchor |
| Reference desk as a test tool | A designed federation: Frontdesk + grounded specialists + register + personas |
| No reason to enliterate stated | The ethic (below) — attention is the act; someone authorizes the spend |
| Governance inherits the top of the ladder | Name `considerer_tier` / `audit_tier`; they write no Visit row, so the tending log cannot show them |
| Provenance stores the tier alias | Store the resolved backend too — an alias can be repointed to another vendor with no code change |
| Trust the gateway's spend log | Verify at the **billing source**; a proxied route can log $0.00 while the provider bills normally |

## The ethic (why, and who decides)

Collecting is future-directed attention — "this matters enough to keep looking at." Economics forced triage; most collections sit physically preserved but intellectually dormant. Enliteration changes the economics so the question flips from "can we afford to examine this?" to "can we afford not to?" The obligation arises from **attention** ("if you make eye contact with trash, it's yours") — but the **conscience** is the person who sees the dormant collection and authorizes the spend. The engine is **infrastructure, not conscience**: a cron job and a credit card. Name the human who reached for their wallet.

## The deep reference (don't duplicate — read the gem's own docs)

This skill is the judgment layer. The mechanics live in the gem and evolve with it — read them, don't re-document them here:
- `/enliterator/about` (`app/views/enliterator/about/index.html.erb`) — the plain-language thesis.
- The engine source and its RSpec suite — the authoritative, version-by-version mechanics.

## Tending log

Each entry is a visit. Read them as a record's history; add yours when you use this skill (see the protocol at the top).

- **Visit 0 — born from HSDL (2026-06-14).** Harvested from the first enliteration: a federation of homeland-security *text* (CHDS theses, CRS reports, executive orders). Everything here is therefore text-native and HSDL-shaped until proven general.
- **Visit 1 — a historical photography archive, in test (2026-06-14).** Applying the draft to a 40,000-image archive surfaced three real gaps, now folded in: (a) vocabulary guidance defaulted to LCSH — generalized to "find the field's own authority" (TGM I/II is primary for graphic materials); (b) the legibility note for non-text was a parenthetical — elevated to a **derive-text-first FOUNDATION** with its own condition probe + accuracy, because for an image archive the derived description IS the substrate the whole loop rests on. **Still open / uncertain:** the engine tends derived TEXT only — whether the LLM adapter should receive the image+description *jointly* for visual-evidence facets (`depicted_persons`, `depicted_location`) is unresolved and needs a real multimodal enliteration to settle. This draft cannot yet speak to audio/video, or to non-narrative collections (code, datasets, objects) — those are unvisited.

- **Visit 2 — a compliance audit reads the record back (2026-08-12).** An institution's IT security office asked its library to confirm which vendor's models were running in its cloud account. Answering from the enliteration's own provenance produced a **confident wrong answer**: the tending log named house aliases (`draft`/`quality`), which read like one vendor, while the gateway resolved them to another. Three gaps, now folded in: (a) **an alias is not provenance** — record the resolved backend beside it, or a repointing silently rewrites the attribution of every later claim (fixed in the engine, v0.68); (b) **governance inherits `ladder.last` and writes no `Visit` row** — the nightly considerer/conservator/examiner had run five weeks on the costliest tier while the tending log showed that tier dormant, so name the governance tiers explicitly and pin the examiner hardest (accuracy is a series); (c) **the gateway's spend log read $0.00 while the provider billed normally**, which is why (b) went unnoticed — reconcile against the billing source, and know which account it is. **The generalizable shape:** all three are the same failure — *the observability surface and the execution surface disagreed, and the observability surface was the one designed to be trusted.* When a collection's own record is the thing being audited, "our log says X" is a hypothesis, not an answer. **Still open:** nothing here was caught by review; it took an outside party asking a question the record was not built to answer. That suggests a periodic *adversarial* read of one's own provenance — pick a claim, prove from the data alone who made it and with what — but that practice is untested.

## Activation

This skill ships in the gem (`skills/enliterating-a-collection/`). A host installs it into `.claude/skills/` (or a generator does) so a Claude working on a host with the engine loads the method. The gem carries both the machinery and the method — that is the point.
