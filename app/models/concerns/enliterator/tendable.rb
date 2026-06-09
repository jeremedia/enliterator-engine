module Enliterator
  module Tendable
    extend ActiveSupport::Concern
    included do
      has_many :enliterator_visits,     class_name: "Enliterator::Visit",     as: :tendable,   dependent: :destroy
      has_many :enliterator_claims,     class_name: "Enliterator::Claim",     as: :tendable,   dependent: :destroy
      has_many :enliterator_measures,     class_name: "Enliterator::Measure",     as: :tendable,   dependent: :destroy
      has_many :enliterator_embeddings,  class_name: "Enliterator::Embedding",  as: :embeddable, dependent: :destroy
      has_many :enliterator_suggestions, class_name: "Enliterator::Suggestion", as: :tendable,   dependent: :destroy
      Enliterator.register_tendable(self)
    end

    # Host SHOULD override to provide the text representation used for embedding + tending.
    # Default tries common fields.
    #
    # v0.4: facet-aware. Different facets may need different source text (e.g. an
    # authorship facet wants the title page, not the abstract). If the host's
    # `to_enliterator_text` accepts a `facet:` keyword, it's passed through; otherwise
    # the zero-arg override is called (back-compat). `facet:` defaults to nil so
    # `enliterator_text` with no args keeps working everywhere.
    def enliterator_text(facet: nil)
      if respond_to?(:to_enliterator_text)
        if method(:to_enliterator_text).parameters.any? { |type, name| name == :facet && %i[key keyreq].include?(type) }
          return to_enliterator_text(facet: facet)
        end
        return to_enliterator_text
      end
      [ try(:title), try(:name), try(:description) ].compact.join("\n")
    end

    # The compounding context handed to each visit.
    #
    # recent_visits reflects only AUTHORITATIVE visits (applied: true). A junior
    # visit that escalated and had its reconciliation discarded is recorded with
    # applied: false (provenance only) and must NOT condition the next tending —
    # otherwise a superseded draft would leak into future prompts. v0.1 visits are
    # all applied: true, so this filter is a no-op for the existing contract.
    def literacy_state(facet: nil)
      {
        claims:        enliterator_claims.live.map(&:to_state),
        recent_visits: enliterator_visits.applied.where(facet: facet).order(created_at: :desc).limit(5).map(&:to_state),
        measures:        enliterator_measures.each_with_object({}) { |f, h| h[f.name] = f.score }
      }
    end

    def tend!(facet:, **opts)
      Enliterator::Tending::Visitor.new(self, facet: facet, **opts).call
    end

    def last_tended_at(facet: nil)
      scope = enliterator_visits.where(status: "succeeded")
      scope = scope.where(facet: facet) if facet
      scope.maximum(:finished_at)
    end

    # Locked-claim import (SPEC.md > v0.3 > §5). Seed structured host metadata as a
    # first-class, governed Claim the LLM never derives — e.g. an authoritative
    # `published_at` pulled from the source record. Upserts THIS record's live claim
    # for `key`: if a live claim exists (superseded_by_id nil AND not tombstoned) it
    # is updated in place; otherwise a new claim is created. Idempotent — calling
    # twice with the same args is a no-op beyond touching the row. Does NOT create a
    # Visit (this is import, not tending). Because reconcile NOOPs locked claims on
    # UPDATE, a locked claim seeded here survives all subsequent tending untouched.
    def assert_claim!(key:, value:, locked: true, status: "verified", attributed_to: "host", tier: nil)
      attrs = {
        value:         value,
        locked:        locked,
        status:        status,
        attributed_to: attributed_to,
        tier:          tier
      }

      existing = enliterator_claims.live.find_by(key: key)
      if existing
        existing.update!(**attrs)
        existing
      else
        enliterator_claims.create!(key: key, **attrs)
      end
    end

    class_methods do
      def enliterator_tendable? = true
    end
  end
end
