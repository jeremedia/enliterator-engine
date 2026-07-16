module Enliterator
  # PROV Entity. A provenanced, reconcilable unit of understanding about a record.
  # Claims are never edited in place; an UPDATE creates a new Claim and supersedes
  # the old one, preserving the provenance chain (prov:wasDerivedFrom).
  class Claim < ApplicationRecord
    belongs_to :tendable, polymorphic: true
    belongs_to :visit, class_name: "Enliterator::Visit", optional: true
    belongs_to :superseded_by, class_name: "Enliterator::Claim", optional: true
    # v0.13: the context this claim is asserted WITHIN. NULL = the root scope
    # (root rule) — true of the record in every lens, inherited by all contexts.
    belongs_to :context, class_name: "Enliterator::Context", optional: true

    # v0.60: `asserted` — a model self-confident claim minted by a capable tier
    # (reconcile-status), distinct from `verified` which is now reserved for a HUMAN
    # standing behind the claim (curator seed / correction). Only minted when
    # config.audit_warrant is on; the `live` scope includes it (not "superseded").
    STATUSES = %w[draft asserted verified superseded].freeze
    REVIEW_STATES = %w[pending approved rejected].freeze

    # v0.18: raised when an action assumes a live claim that has since been
    # superseded (e.g. a human correction racing a re-tend) — a second
    # supersede! would corrupt the chain.
    class AlreadySuperseded < StandardError; end

    # The latest claim in a supersession chain.
    scope :current, -> { where(superseded_by_id: nil) }
    # Current AND not tombstoned (a DELETE supersedes without a replacement).
    scope :live,    -> { current.where.not(status: "superseded") }
    # v0.24 (extracted from the Atlas): claims that ARE understanding —
    # engine-derived (visit-stamped) plus curator corrections (human:*).
    # Excludes the condition reconciler's locked source_status flags and host
    # assert_claim! seeds: flags and catalog facts are not tended understanding.
    scope :understanding, -> { where("visit_id IS NOT NULL OR attributed_to LIKE 'human%'") }

    # Compact projection for literacy_state / prompt context.
    #
    # v0.60: when config.audit_warrant is on, the honest `warrant` rides along so a
    # reader (the tend prompt, an agent) sees an unaudited model claim as `asserted`,
    # not `verified`. Flag off ⇒ the key is absent ⇒ byte-identical.
    def to_state
      h = {
        key:        key,
        value:      value,
        confidence: confidence,
        status:     status,
        locked:     locked
      }
      h[:warrant] = warrant if Enliterator.configuration.audit_warrant
      h
    end

    # v0.60: the claim's honest EPISTEMIC state, derived (no column). The audit
    # dimension (the latest instrument verdict) OUTRANKS the reconcile-status, so a
    # `verified`/`asserted` claim an examiner contradicted reads `contradicted`, and a
    # human-supported one reads `human_verified`. With no audit, a locked human claim
    # is `human_verified`; otherwise the reconcile-status stands (draft / asserted /
    # verified). Staleness is a SEPARATE axis (host display / re-derive), not folded in.
    def warrant
      return "superseded" if status == "superseded"

      if (av = latest_audit_verdict)
        src, verdict = av
        return "human_verified"     if src == "human" && verdict == "supported"
        return "examiner_supported" if verdict == "supported"
        return "contradicted"       if verdict == "unsupported" || verdict == "contradicted"
        # "unverifiable" carries no positive/negative warrant — fall through.
      end

      return "human_verified" if human_authored?
      status
    end

    # The effective audit verdict for THIS claim as `[source, verdict]`, or nil when
    # unaudited — the canonical human-outranks-examiner precedence
    # (Audit.effective_verdict_pairs), the single source of truth shared with the Atlas.
    def latest_audit_verdict
      Enliterator::Audit.effective_verdict_pairs([ id ])[id]
    end

    # Mark this claim superseded by a newer one. Used by the reconcile contract on
    # UPDATE (replacement) — locked claims are protected upstream in the Visitor.
    def supersede!(by_claim)
      update!(status: "superseded", superseded_by: by_claim)
    end

    private

    # A human stands behind this claim: a curator correction (correct_claim!) or a
    # human-attributed anchor — locked AND attributed to a human. Host seeds
    # (attributed_to "host") are NOT human-authored; their warrant rests on `status`.
    def human_authored?
      locked && attributed_to.to_s.start_with?("human")
    end
  end
end
