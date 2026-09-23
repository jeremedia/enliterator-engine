module Enliterator
  # v0.45: name authority control — the value-side parallel to the self-governing
  # key vocabulary. One row is an authority record: `canonical` is the preferred
  # form, `variants` the see-from spellings that resolve to it. Surfaces (Catalog
  # tally, Atlas) resolve a name VALUE to its canonical at READ TIME; raw claims
  # are never rewritten. Empty table (or no record for a value) ⇒ identity ⇒
  # byte-identical to pre-v0.45. Scoped up the context path like claims/vocabulary.
  #
  # The full governed loop (propose → pressure → consider → ratify name merges) is
  # deferred; v1 ships the store + a deterministic reconciler. `status`:
  #   auto      — applied (deterministic high-confidence merge)
  #   ratified  — applied (human-confirmed)
  #   held      — NOT applied (ambiguous / concatenated merge-error, awaiting review)
  class NameAuthority < ApplicationRecord
    APPLIED = %w[auto ratified].freeze

    # The canonical (preferred) form for a name value, or the value unchanged when
    # unmapped. Convenience for single lookups; hot paths build map_for once.
    def self.canonical_for(value, context: nil)
      map_for(context: context)[value.to_s] || value
    end

    # All see-from forms for a canonical (including itself) — used to expand a
    # heading value back to every variant when querying records.
    def self.variants_for(canonical, context: nil)
      rec = in_scope(context).find_by(canonical: canonical)
      rec ? ([ rec.canonical ] + Array(rec.variants)).uniq : [ canonical ]
    end

    # The resolution map { value => canonical } for a context (canonical → itself
    # included), built from APPLIED records only. Load ONCE per Catalog/Atlas build.
    def self.map_for(context: nil)
      in_scope(context).where(status: APPLIED).each_with_object({}) do |a, h|
        h[a.canonical] = a.canonical
        Array(a.variants).each { |v| h[v.to_s] = a.canonical }
      end
    end

    # Records in scope for a context: the context's path (root included), or just
    # root when no context. v0.78: resolution is a READ (Catalog/Atlas headings),
    # so it follows Context#read_scope_ids — a parent view must merge the name
    # variants its children's authorities cover, or the advisor claims it can now
    # see would fragment across spellings again. Leaf: == scope_ids (unchanged).
    # The reconciler WRITES through its own scope (NameReconciler#scope_ids).
    def self.in_scope(context)
      ids = if context.respond_to?(:read_scope_ids) then context.read_scope_ids
            elsif context.respond_to?(:scope_ids) then context.scope_ids
            else [ context&.id ]
            end
      where(context_id: ids)
    end
  end
end
