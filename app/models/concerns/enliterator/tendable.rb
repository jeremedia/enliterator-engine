module Enliterator
  module Tendable
    extend ActiveSupport::Concern
    included do
      has_many :enliterator_visits,     class_name: "Enliterator::Visit",     as: :tendable,   dependent: :destroy
      has_many :enliterator_claims,     class_name: "Enliterator::Claim",     as: :tendable,   dependent: :destroy
      has_many :enliterator_facets,     class_name: "Enliterator::Facet",     as: :tendable,   dependent: :destroy
      has_many :enliterator_embeddings,  class_name: "Enliterator::Embedding",  as: :embeddable, dependent: :destroy
      has_many :enliterator_suggestions, class_name: "Enliterator::Suggestion", as: :tendable,   dependent: :destroy
      Enliterator.register_tendable(self)
    end

    # Host SHOULD override to provide the text representation used for embedding + tending.
    # Default tries common fields.
    def enliterator_text
      return to_enliterator_text if respond_to?(:to_enliterator_text)
      [ try(:title), try(:name), try(:description) ].compact.join("\n")
    end

    # The compounding context handed to each visit.
    #
    # recent_visits reflects only AUTHORITATIVE visits (applied: true). A junior
    # visit that escalated and had its reconciliation discarded is recorded with
    # applied: false (provenance only) and must NOT condition the next tending —
    # otherwise a superseded draft would leak into future prompts. v0.1 visits are
    # all applied: true, so this filter is a no-op for the existing contract.
    def literacy_state(stream: nil)
      {
        claims:        enliterator_claims.live.map(&:to_state),
        recent_visits: enliterator_visits.applied.where(stream: stream).order(created_at: :desc).limit(5).map(&:to_state),
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
