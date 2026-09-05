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

    # v0.73: raised when adjudicating a key ABSENT would supersede a locked
    # NON-BLANK claim — a curator already ruled a VALUE for this key, and
    # ruling absence over it is a contradiction between curators that must
    # fail loudly, never quietly win. The surface renders it as an alert
    # naming the conflicting value, not a stack trace.
    class AdjudicationConflict < StandardError; end

    # v0.72: THE definition of an empty claim value — one predicate shared by
    # the reader loop (v0.46 blank handling), the examiner (the absence
    # verdict), and the measurement stack (abstention metrics). Two definitions
    # of "empty" would let the reader and its instrument disagree about which
    # claims assert absence.
    def self.blank_value?(value)
      return true if value.nil?
      return value.strip.empty? if value.is_a?(String)
      return value.empty? if value.respond_to?(:empty?)
      false
    end

    # The latest claim in a supersession chain.
    scope :current, -> { where(superseded_by_id: nil) }
    # Current AND not tombstoned (a DELETE supersedes without a replacement).
    scope :live,    -> { current.where.not(status: "superseded") }
    # v0.24 (extracted from the Atlas): claims that ARE understanding —
    # engine-derived (visit-stamped) plus curator corrections (human:*).
    # Excludes the condition reconciler's locked source_status flags and host
    # assert_claim! seeds: flags and catalog facts are not tended understanding.
    scope :understanding, -> { where("visit_id IS NOT NULL OR attributed_to LIKE 'human%'") }
    # v0.75 (extracted): the examinable population — live, engine-derived
    # (visit-bearing), unlocked. THE one definition; the audit sampler and the
    # census both compose from it (they had drifted into near-duplicates).
    scope :examinable, -> { live.where(locked: false).where.not(visit_id: nil) }

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
    # verified). Staleness remains a SEPARATE axis, not folded in — v0.75 gives that
    # axis its sibling predicates: `warrant_checked_digest` / `warrant_stale?`.
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

    # v0.75 — WARRANT IN TIME. The digest of the source text this claim was last
    # actually CHECKED against: the latest instrument audit's source_digest (an
    # audit re-examines — human or examiner, either is a check), else the minting
    # visit's source_digest (the v0.75 warrant paper). nil for claims whose last
    # check predates the instrument — unknowable, not fresh.
    def warrant_checked_digest
      audit = Enliterator::Audit.instrument.where(claim_id: id)
                                .where.not(source_digest: nil)
                                .order(:created_at).last
      return audit.source_digest if audit
      visit&.source_digest
    end

    # Has the terrain moved under this claim since anything checked it?
    # OKNOTOK's warrant_stale? shape: the acceptance predicate re-evaluated NOW;
    # derived, never stored; an INSTRUMENT, never an auto-revoker (probable
    # cause has a shelf life — search warrants void unexecuted).
    #
    # THREE-state: true (checked digest ≠ current), false (they match), nil
    # (UNKNOWN — no checked digest exists, or no current one is derivable).
    # UNKNOWN is never conflated with fresh OR stale; pre-v0.75 claims are
    # unknowable and the instrument grows honestly as digests accumulate.
    #
    # `current_digest` lets a page amortize the text read per record (the
    # review-controller idiom). Without it, falls back to STORE-vs-STORE: the
    # record's newest succeeded visit for this claim's facet that carries a
    # digest — zero text reads.
    def warrant_stale?(current_digest = nil)
      checked = warrant_checked_digest
      return nil if checked.nil?

      current = current_digest || latest_known_source_digest
      return nil if current.nil?

      checked != current
    end

    # v0.76 — DERIVATION TAINT: fruit of the poisonous tree, read at serve time.
    # Walks this claim's BASIS ancestors (derived_from entries with
    # role:"basis" — the taint-carrying edge minted by deep-read synthesis) and
    # returns true when any ancestor within TAINT_DEPTH hops is POISONED:
    # its effective verdict is defective (human outranks examiner), or it was
    # superseded by a human anchor (correction and adjudication share that
    # shape — locked + human-attributed successor). Plain model supersession
    # is NEVER poison: role-less LINEAGE edges are never walked — the
    # successor is the cure, not the victim.
    #
    # CURE (independent source): the claim cited its way out — its OWN
    # effective verdict is `supported` and NEWER than the latest poisoning
    # event among its ancestors. Taint MARKS, never deletes; derived at read,
    # never stored (a derived diagnosis can't itself go stale).
    #
    # false means NO KNOWN taint — absence of basis edges is not innocence
    # (pre-v0.76 synthesis claims carry no edges); the instrument grows as
    # edges accumulate, the v0.75 honesty pattern.
    TAINT_DEPTH = 3

    def tainted?
      self.class.taint_for([ self ])[id]
    end

    # Batch taint for claim-listing pages (the warrant_staleness_for pattern):
    # bounded queries per HOP over the whole set, never per claim. Returns
    # {claim_id => true|false}.
    def self.taint_for(claims)
      claims = Array(claims)
      return {} if claims.empty?

      out      = claims.to_h { |c| [ c.id, false ] }
      frontier = {}                                  # origin id => ancestor ids this hop
      seen     = Hash.new { |h, k| h[k] = Set.new }  # per-origin cycle guard
      poisons  = Hash.new { |h, k| h[k] = [] }       # origin id => poison times

      claims.each do |c|
        ids = basis_ids_of(c)
        frontier[c.id] = ids if ids.any?
      end
      return out if frontier.empty?

      TAINT_DEPTH.times do
        ancestor_ids = frontier.values.flatten.uniq
        break if ancestor_ids.empty?

        ancestors  = where(id: ancestor_ids).index_by(&:id)
        poison_map = poison_times_for(ancestors.values)

        next_frontier = {}
        frontier.each do |origin, ids|
          ids.each do |aid|
            next if seen[origin].include?(aid)
            seen[origin] << aid
            poisons[origin] << poison_map[aid] if poison_map[aid]
            anc = ancestors[aid]
            nxt = anc ? basis_ids_of(anc) : []
            (next_frontier[origin] ||= []).concat(nxt) if nxt.any?
          end
        end
        frontier = next_frontier
        break if frontier.empty?
      end

      poisoned = poisons.select { |_, times| times.any? }
      return out if poisoned.empty?

      # The cure: an origin's own supported verdict, newer than its LATEST
      # poisoning event, clears it (it grounded independently after the
      # basis went bad).
      own = Enliterator::Audit.effective_verdict_pairs(poisoned.keys, with_time: true)
      poisoned.each do |origin, times|
        _src, verdict, at = own[origin]
        cured = verdict == "supported" && at && at > times.max
        out[origin] = true unless cured
      end
      out
    end

    # The taint-carrying edges only — role:"basis" refs. Role-less entries
    # are lineage (supersession/correction) and are structurally excluded.
    def self.basis_ids_of(claim)
      Array(claim.derived_from).filter_map do |ref|
        ref["id"] if ref.is_a?(Hash) && ref["type"] == "claim" && ref["role"] == "basis"
      end
    end

    # {claim_id => poison time} over a batch of ancestor claims. Two poison
    # shapes: a DEFECTIVE effective verdict (the instrument ruled it wrong),
    # or supersession by a human anchor — correct_claim! and adjudicate_absent!
    # both mint locked + human-attributed successors, and either implies the
    # ancestor was refused by a curator even where no audit row exists.
    def self.poison_times_for(ancestor_claims)
      return {} if ancestor_claims.empty?

      poison   = {}
      verdicts = Enliterator::Audit.effective_verdict_pairs(ancestor_claims.map(&:id), with_time: true)
      verdicts.each do |cid, (_src, verdict, at)|
        poison[cid] = at if Enliterator::Audit::DEFECTIVE.include?(verdict)
      end

      succ_ids = ancestor_claims.filter_map(&:superseded_by_id)
      if succ_ids.any?
        successors = where(id: succ_ids).index_by(&:id)
        ancestor_claims.each do |anc|
          s = successors[anc.superseded_by_id]
          next unless s && s.locked && s.attributed_to.to_s.start_with?("human")
          poison[anc.id] = [ poison[anc.id], s.created_at ].compact.max
        end
      end
      poison
    end

    # v0.75 batch helper for claim-listing pages — one audits query + one visits
    # query for N claims (latest_audit_verdict's per-claim shape must not be
    # repeated here). `current_digests` maps [tendable_type, tendable_id, facet]
    # => digest for callers that computed current text; absent keys fall back to
    # the stored latest-visit digest. Returns {claim_id => true|false|nil}.
    def self.warrant_staleness_for(claims, current_digests: {})
      claims = Array(claims)
      return {} if claims.empty?

      audit_digests = Enliterator::Audit.instrument
                                        .where(claim_id: claims.map(&:id))
                                        .where.not(source_digest: nil)
                                        .order(:created_at)
                                        .pluck(:claim_id, :source_digest).to_h

      # Newest stored digest per (record, facet) — one query over the visits of
      # the claims' records, newest last so the hash keeps the latest.
      visit_ids = claims.filter_map(&:visit_id)
      mint = Enliterator::Visit.where(id: visit_ids).pluck(:id, :source_digest, :facet)
                               .each_with_object({}) { |(id, dig, facet), h| h[id] = [ dig, facet ] }
      keys = claims.map { |c| [ c.tendable_type, c.tendable_id ] }.uniq
      latest = Enliterator::Visit.where(status: "succeeded").where.not(source_digest: nil)
                                 .where(keys.map { "(tendable_type = ? AND tendable_id = ?)" }.join(" OR "),
                                        *keys.flatten)
                                 .order(:started_at)
                                 .pluck(:tendable_type, :tendable_id, :facet, :source_digest)
                                 .each_with_object({}) { |(ty, tid, f, dig), h| h[[ ty, tid, f ]] = dig }

      claims.each_with_object({}) do |c, out|
        mint_dig, mint_facet = mint[c.visit_id]
        checked = audit_digests[c.id] || mint_dig
        next out[c.id] = nil if checked.nil?

        facet   = mint_facet
        current = (facet && current_digests[[ c.tendable_type, c.tendable_id, facet ]]) ||
                  (facet && latest[[ c.tendable_type, c.tendable_id, facet ]])
        out[c.id] = current.nil? ? nil : checked != current
      end
    end

    # Mark this claim superseded by a newer one. Used by the reconcile contract on
    # UPDATE (replacement) — locked claims are protected upstream in the Visitor.
    def supersede!(by_claim)
      update!(status: "superseded", superseded_by: by_claim)
    end

    private

    # v0.75: the newest stored digest for this claim's (record, facet) — the
    # store-vs-store staleness comparison, zero text reads. nil when the facet
    # is unknowable (visit-less claim) or no digest-bearing visit exists yet.
    def latest_known_source_digest
      facet = visit&.facet
      return nil if facet.nil?

      Enliterator::Visit.where(tendable_type: tendable_type, tendable_id: tendable_id,
                               facet: facet, status: "succeeded")
                        .where.not(source_digest: nil)
                        .order(:started_at).last&.source_digest
    end

    # A human stands behind this claim: a curator correction (correct_claim!) or a
    # human-attributed anchor — locked AND attributed to a human. Host seeds
    # (attributed_to "host") are NOT human-authored; their warrant rests on `status`.
    def human_authored?
      locked && attributed_to.to_s.start_with?("human")
    end
  end
end
