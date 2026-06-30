module Enliterator
  # The authority file (v0.51) — the standing controlled vocabulary drawn as a
  # thesaurus: each PREFERRED term (a code term or a curator-approved one) shown with
  # the UF variants folded onto it, ranked by sprawl, with the diagnostics a curator
  # needs to spot trouble — dumping grounds (one term absorbing variants from many
  # facets) and the one-off tail (proposed keys seen on a single record, the proliferation
  # signal). The companion to the Requests queue (/suggestions): Requests is the PENDING
  # decisions; this is the RESOLVED, standing vocabulary.
  #
  # Read-only and context-scoped (rule 4: a context shows its OWN authority file). Queries
  # LIVE — this is the surface curator corrections (v0.52) mutate, so it must reflect a fix
  # immediately and must NOT serve a stale ring from a heartbeat-keyed cache (a correction
  # creates no Heartbeat row). The Requests surface queries live every request for the same
  # reason. `canonical_keys` (the legal correction targets) lives here so v0.52 reuses it.
  class Authority
    # A preferred term whose folded variants span at least this many distinct facets is
    # flagged as a "dumping ground" — the unmet_concepts-as-catch-all smell.
    DUMPING_GROUND_FACETS = 3

    def initialize(context: nil)
      @context = context
    end

    # The whole authority file for this context, as a plain hash (computed live).
    def overview
      synonyms      = scoped.synonyms                 # [{facet, proposed_key, mapped_to}] — the UF folds
      approved_keys = scoped.contract_additions.values.flatten.uniq  # the preferred (approved) terms
      rings         = build_rings(synonyms, approved_keys)
      {
        rings:     rings,                             # ranked preferred terms + their variants
        metrics:   metrics(rings, approved_keys),     # proliferation diagnostics (the baseline numbers)
        facets:    facet_rollup,                      # {facet => {pending:, approved:, mapped:, rejected:}}
        canonical: canonical_keys                     # legal correction targets (reused by v0.52)
      }
    end

    # Legal preferred-term targets in this context: the effective vocabulary across the
    # context's facets (code terms + curator-approved). Mirrors SuggestionsController's
    # private helper and the considerer's; the one reusable copy lives here.
    def canonical_keys
      Enliterator.staffing.facets_for(@context&.path_keys).keys
        .flat_map { |s| (Enliterator::Vocabulary.for(s, context: @context) || {}).keys }
        .uniq.sort
    end

    private

    # Every aggregation reads through here, so the surface is context-scoped (rule 4) —
    # the unscoped class methods (synonyms/contract_additions) chain on top.
    def scoped
      Enliterator::Suggestion.where(context_id: @context&.id)
    end

    # Each ring = a preferred term + the variants folded onto it (rows where mapped_to ==
    # term), ordered by sprawl (variant count, then name). Preferred terms come from BOTH
    # the approved set AND any term that is a USE target (a code term can head a ring
    # without an approved row), so the full standing vocabulary is shown — an approved term
    # with no variants yet still appears (an empty ring).
    def build_rings(synonyms, approved_keys)
      variants_by_target = synonyms.group_by { |s| s[:mapped_to] }
      canon              = canonical_keys.to_set
      preferred          = (variants_by_target.keys + approved_keys).compact.uniq

      preferred.map { |term|
        vs           = variants_by_target[term] || []
        variant_keys = vs.map { |v| v[:proposed_key] }.uniq.sort
        facets       = vs.map { |v| v[:facet] }.compact.uniq.sort
        {
          term:           term,
          approved:       approved_keys.include?(term),
          canonical:      canon.include?(term),             # legal target (code or approved)
          variants:       variant_keys,
          variant_count:  variant_keys.size,
          facets:         facets,
          dumping_ground: facets.size >= DUMPING_GROUND_FACETS
        }
      }.sort_by { |r| [ -r[:variant_count], r[:term].to_s ] }
    end

    # The proliferation diagnostics, context-scoped, over ALL statuses (NOT pending-only —
    # the one-off tail includes resolved one-offs; that share is the experiment's headline).
    # The per-key distinct-record count uses the same shape Suggestion.gaps uses.
    def metrics(rings, approved_keys)
      per_key  = scoped.group(:proposed_key)
                       .distinct.count(Arel.sql("tendable_type || ':' || tendable_id"))
      total    = per_key.size
      one_offs = per_key.count { |_key, n| n == 1 }
      variants = rings.sum { |r| r[:variant_count] }
      preferred = approved_keys.size
      {
        distinct_keys:   total,
        preferred_terms: preferred,
        variant_keys:    variants,
        proliferation:   (preferred.zero? ? nil : (variants.to_f / preferred).round(2)),
        one_off_keys:    one_offs,
        one_off_pct:     (total.zero? ? nil : (100.0 * one_offs / total).round)
      }
    end

    # {facet => {"pending" => n, "approved" => n, "mapped" => n, "rejected" => n}} —
    # context-scoped. Built plainly (no default-proc hash — keeps the payload marshalable
    # in case a caller ever caches it).
    def facet_rollup
      rollup = {}
      scoped.group(:facet, :status).count.each do |(facet, status), n|
        (rollup[facet] ||= { "pending" => 0, "approved" => 0, "mapped" => 0, "rejected" => 0 })[status] = n
      end
      rollup
    end
  end
end
