---
name: enliterating-a-collection
description: Use when conferring literacy on a collection with the Enliterator engine — modeling a new host collection or context, designing its facets, staffing tiers, controlled vocabulary, conditions, or reference desks, or planning a tending campaign. The judgment layer for wielding the gem's machinery.
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

4. **Design the staffing policy (the org chart).** Facets are **roles**; LiteLLM aliases are **capability tiers** (`cheap`/`quality`/`bedrock-sonnet`…). Set the **escalation ladder** (low-confidence draft → higher tier), the **verify floor** (only the top tier — or a human — may mint `verified`), the embedding tier, and `escalation_threshold`. First pass cheap for coverage; reconcile dense neighbor clusters at quality.

5. **Let the vocabulary govern itself.** Code terms seed it; off-vocabulary observations become `Suggestion`s → pressure accumulates in `ProposedTerm` → the **Considerer** auto-applies safe verdicts and holds approvals → ratify → the term goes **live** and re-proposals are **suppressed** (the loop converges). This is authority control, not "an archivist reviews a queue weekly."

6. **Condition: make the collection shelf-read itself — and gate tending on it.** Register `Condition` probes (present → intact → legible). The **legibility probe `gates_tending`**: a title-only catalog card or an un-transcribed scan is *untendable* until text arrives — do not spend tokens tending what the engine can't read. Run a survey to inventory condition first.

   **Non-text collections — derive text first (this is the FOUNDATION, not a footnote).** The engine tends TEXT (`to_enliterator_text`). For images/audio/video, "legible" means *derived text exists*: a **derive-text-first phase** (multimodal description, caption/verso OCR, transcription) runs BEFORE tending and produces the substrate the engine then reads. Give it its own condition probe (e.g. `described`) that `gates_tending`, its OWN accuracy measurement, and store the derived description as a first-class artifact (version it — re-derivation will improve). **The derived description is to a photograph what the abstract is to a thesis** — the entire compounding loop rests on its quality, so give it comparable care. (Open question being tended: whether some facets should tend the image+description jointly, not just the derived text — see the tending log.)

7. **Run it on the heartbeat (event-driven, bounded).** Frontier first (untended members — highest claims/dollar), re-tend on **change** (source / neighborhood / vocabulary), `stale_after` as a slow safety net. A per-cycle **token budget** the cycle cannot exceed. The pacemaker is a host scheduler (launchd/cron). Re-reading unchanged surroundings is pure NOOP spend — the triggers exist to avoid it.

8. **Measure accuracy — don't assert it.** The **Audit**: stratified sampling, a *blind, full-text-grounded* examiner, **process-rate** accuracy (audits never age out; re-tending can't launder a bad number), and a **human anchor** (the Review surface — confirm/overrule/correct). Accuracy is a standing measured number, not a one-time spot check.

9. **The surfaces are the finding aid, made plural.** Status (finding aid + health), Catalog (OPAC), Atlas (the claim graph — the vocabulary IS the legend), Reference Desk (the chat), Requests (authority-control queue), Heartbeat (the pulse), About (the living thesis doc — keep it true). Compose new UI from the layout's tokens/components; 100% inline (no CDN/gems/web-fonts — a Sprockets host 500s otherwise).

10. **Design the Reference Desk.** A **Frontdesk** triages and routes; **grounded-but-not-walled specialists** advise within a context but may reach siblings. The engine owns the **institutional register** (anti-chipper, collection-as-subject — `config.chat_register`); the host supplies domain + persona, curator-editable and versioned (`/desks`). The Loop, not the prompt, is the enforcement boundary — so personas are safe to edit.

## The build discipline (when extending the engine)

byte-identical back-compat (every feature additive + gated; suite green when unused) · 100% inline UI · no silent failures (every early return logs why) · build IN not TO · greatness or external force (no rough seams) · the process: **brainstorm → spec → plan → subagent-driven build → live-verify → memory**; versions = commits + SPEC.md section + tag. Prefer driving the desk via `Chat::Eval` / `enliterator:ask` (no browser) for evaluation.

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

## The ethic (why, and who decides)

Collecting is future-directed attention — "this matters enough to keep looking at." Economics forced triage; most collections sit physically preserved but intellectually dormant. Enliteration changes the economics so the question flips from "can we afford to examine this?" to "can we afford not to?" The obligation arises from **attention** ("if you make eye contact with trash, it's yours") — but the **conscience** is the person who sees the dormant collection and authorizes the spend. The engine is **infrastructure, not conscience**: a cron job and a credit card. Name the human who reached for their wallet.

## The deep reference (don't duplicate — read the gem's own docs)

This skill is the judgment layer. The mechanics live in the gem and evolve with it — read them, don't re-document them here:
- `SPEC.md` — the version-by-version build record (the authoritative mechanics).
- `/enliterator/about` (`app/views/enliterator/about/index.html.erb`) — the plain-language thesis.
- `CLAUDE.md` — the project's hard rules, vocabulary, and standing directives.
- `docs/superpowers/specs/` & `docs/superpowers/plans/` — design docs for each feature (worked examples of the method).

## Tending log

Each entry is a visit. Read them as a record's history; add yours when you use this skill (see the protocol at the top).

- **Visit 0 — born from HSDL (2026-06-14).** Harvested from the first enliteration: a federation of homeland-security *text* (CHDS theses, CRS reports, executive orders). Everything here is therefore text-native and HSDL-shaped until proven general.
- **Visit 1 — a historical photography archive, in test (2026-06-14).** Applying the draft to a 40,000-image archive surfaced three real gaps, now folded in: (a) vocabulary guidance defaulted to LCSH — generalized to "find the field's own authority" (TGM I/II is primary for graphic materials); (b) the legibility note for non-text was a parenthetical — elevated to a **derive-text-first FOUNDATION** with its own condition probe + accuracy, because for an image archive the derived description IS the substrate the whole loop rests on. **Still open / uncertain:** the engine tends derived TEXT only — whether the LLM adapter should receive the image+description *jointly* for visual-evidence facets (`depicted_persons`, `depicted_location`) is unresolved and needs a real multimodal enliteration to settle. This draft cannot yet speak to audio/video, or to non-narrative collections (code, datasets, objects) — those are unvisited.

## Activation

This skill ships in the gem (`skills/enliterating-a-collection/`). A host installs it into `.claude/skills/` (or a generator does) so a Claude working on a host with the engine loads the method. The gem carries both the machinery and the method — that is the point.
