module Enliterator
  module Tendable
    extend ActiveSupport::Concern
    included do
      has_many :enliterator_visits,     class_name: "Enliterator::Visit",     as: :tendable,   dependent: :destroy
      has_many :enliterator_claims,     class_name: "Enliterator::Claim",     as: :tendable,   dependent: :destroy
      has_many :enliterator_measures,     class_name: "Enliterator::Measure",     as: :tendable,   dependent: :destroy
      has_many :enliterator_embeddings,  class_name: "Enliterator::Embedding",  as: :embeddable, dependent: :destroy
      has_many :enliterator_suggestions, class_name: "Enliterator::Suggestion", as: :tendable,   dependent: :destroy
      # v0.13: an item lives in the root collection implicitly and in any number
      # of labeled sub-contexts explicitly (the M2M lens membership).
      has_many :enliterator_context_memberships, class_name: "Enliterator::ContextMembership",
                                                 as: :member, dependent: :destroy
      has_many :enliterator_contexts, through: :enliterator_context_memberships, source: :context
      # v0.25: the registry is for HOST models — engine-internal tendables
      # (Enliterator::Part) get the full machinery but must not enter the
      # planner's root lanes, the corpus census, or the condition survey.
      Enliterator.register_tendable(self) unless name.to_s.start_with?("Enliterator::")
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
    # v0.13: context-aware. Tending IN a context reads cumulatively up the
    # ancestry (root rule): the context's own claims plus every ancestor's plus
    # root (NULL), each labeled with its context key so the model can tell
    # inherited intrinsic claims from this lens's own. With no context the read
    # is unfiltered — byte-identical to v0.12 (and the root/aggregate view).
    def literacy_state(facet: nil, context: nil)
      claims = enliterator_claims.live
      visits = enliterator_visits.applied.where(facet: facet)
      if context
        claims = claims.where(context_id: context.scope_ids).includes(:context)
        visits = visits.where(context_id: context.scope_ids)
      end
      {
        claims:        claims.map { |c| context ? c.to_state.merge(context: c.context&.key || "root") : c.to_state },
        recent_visits: visits.order(created_at: :desc).limit(5).map(&:to_state),
        measures:        enliterator_measures.each_with_object({}) { |f, h| h[f.name] = f.score }
      }
    end

    def tend!(facet:, context: nil, **opts)
      Enliterator::Tending::Visitor.new(self, facet: facet, context: context, **opts).call
    end

    # Idempotently place this record in a Context (the M2M lens membership).
    def place_in_context!(context)
      Enliterator::ContextMembership.find_or_create_by!(context: context, member: self)
    end

    def last_tended_at(facet: nil, context: nil)
      scope = enliterator_visits.where(status: "succeeded")
      scope = scope.where(facet: facet) if facet
      scope = scope.where(context_id: context&.id) if context
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
    # v0.13: context-scoped — `context: nil` asserts at root (NULL, the root
    # rule), exactly where all pre-v0.13 locked claims already live.
    def assert_claim!(key:, value:, locked: true, status: "verified", attributed_to: "host", tier: nil, context: nil)
      attrs = {
        value:         value,
        locked:        locked,
        status:        status,
        attributed_to: attributed_to,
        tier:          tier
      }

      existing = enliterator_claims.live.find_by(key: key, context_id: context&.id)
      if existing
        existing.update!(**attrs)
        existing
      else
        enliterator_claims.create!(key: key, context: context, **attrs)
      end
    end

    # Correct a wrong claim with a human verdict (v0.18, the Review surface's
    # write path). NOT assert_claim! — that updates in place, which would
    # mutate the audited value under its own audit row and violate the claims
    # contract ("never edited in place"). This mints a NEW claim — same key,
    # SAME context (reconcile is context-scoped), locked (curator anchor:
    # future reconciles NOOP it), verified, human-attributed, derived from the
    # claim it corrects — then supersedes the old one. literacy_state carries
    # the correction into every future tend: the fix feeds back.
    #
    # Raises Claim::AlreadySuperseded if a re-tend got there first (the
    # surface should re-check liveness and render the successor instead).
    def correct_claim!(claim, value:, note: nil)
      raise ArgumentError, "claim belongs to a different record" unless claim.tendable == self
      if claim.superseded_by_id.present? || claim.status == "superseded"
        raise Enliterator::Claim::AlreadySuperseded,
              "claim ##{claim.id} (#{claim.key}) was superseded after examination"
      end

      fresh = enliterator_claims.create!(
        key:           claim.key,
        context_id:    claim.context_id,
        value:         value,
        locked:        true,
        status:        "verified",
        visit:         nil,
        attributed_to: note.present? ? "human:#{note}" : "human",
        derived_from:  [ { "type" => "claim", "id" => claim.id } ]
      )
      claim.supersede!(fresh)
      fresh
    end

    # Retract a host-asserted claim (v0.17): tombstone the live claim for
    # `key` in the given scope — `status: "superseded"` with no successor,
    # exactly the loop's own DELETE shape, so trajectory/state reconstruction
    # reads it correctly. The missing inverse of assert_claim!: a condition
    # survey that asserts source_status when a record fails must be able to
    # withdraw the note when the record recovers. No-op (nil) when no live
    # claim exists.
    def retract_claim!(key:, context: nil)
      claim = enliterator_claims.live.find_by(key: key, context_id: context&.id)
      return nil if claim.nil?
      claim.update!(status: "superseded")
      claim
    end

    class_methods do
      def enliterator_tendable? = true
    end
  end
end
