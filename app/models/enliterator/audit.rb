module Enliterator
  # v0.18: one examination of one claim — quality review for the claim store
  # (the cataloger's "revision" function, distinct from authority control).
  # source: "examiner" (the LLM, Audit::Examiner) or "human" (the anchor — the
  # only independent ground truth the instrument has). Multiple audits per
  # claim are the design: examiner verdicts are CALIBRATED by human ones.
  #
  # Append-only by convention. Accuracy is a PROCESS rate: audits never age
  # out when their claim is superseded — a live-only rate would let re-tending
  # launder the number (every supersession swaps an audited claim for an
  # unaudited one). The class methods (sample/accuracy/anchor_agreement) are
  # the instrument; Audit::Examiner renders the LLM verdicts.
  class Audit < ApplicationRecord
    VERDICTS = %w[supported unsupported contradicted unverifiable].freeze
    # v0.26 adds "agent": a conversational agent's flag filed through the MCP
    # surface — EYES for the immune system, never part of the instrument. The
    # accuracy/agreement math and the examiner's sampling pool scope to
    # `instrument` (examiner + human) so an agent flag changes NO number; its
    # whole purpose is to reach a human on /review.
    SOURCES  = %w[examiner human agent].freeze
    # supported vs DEFECTIVE is the binary the anchor-agreement headline uses;
    # unverifiable pairs are excluded from agreement entirely.
    DEFECTIVE = %w[unsupported contradicted].freeze

    belongs_to :claim, class_name: "Enliterator::Claim"
    belongs_to :corrected_claim, class_name: "Enliterator::Claim", optional: true
    belongs_to :heartbeat, class_name: "Enliterator::Heartbeat", optional: true

    validates :verdict, inclusion: { in: VERDICTS }
    validates :source,  inclusion: { in: SOURCES }

    scope :examiner,   -> { where(source: "examiner") }
    scope :human,      -> { where(source: "human") }
    scope :agent,      -> { where(source: "agent") }
    # The v0.18 instrument's evidence: examiner verdicts calibrated by human ones.
    scope :instrument, -> { where(source: %w[examiner human]) }

    def defective? = DEFECTIVE.include?(verdict)

    MIN_AGREEMENT_OVERLAPS = 10

    class << self
      # Stratified uniform-random sample for examination: per facet × tier
      # cell (the report's cell — facet via the claim's visit; tier NULL
      # buckets as "unknown"; strata are GLOBAL, context is a drill-down
      # label), round-robin `n` across cells that still have unaudited
      # claims, ORDER BY random() within each. Candidates: live,
      # engine-derived (visit_id NOT NULL — host claims aren't the model's
      # accuracy), unlocked, never audited. Returns {claims:, allocation:}.
      def sample(n)
        return { claims: [], allocation: {} } if n <= 0

        cells = candidate_scope
                  .joins("JOIN enliterator_visits sv ON sv.id = enliterator_claims.visit_id")
                  .group(Arel.sql("sv.facet"), Arel.sql("COALESCE(enliterator_claims.tier, 'unknown')"))
                  .count
        return { claims: [], allocation: {} } if cells.empty?

        # Round-robin allocation across cells, capped by each cell's
        # population. Ties break RANDOMLY: with n below the cell count, an
        # alphabetical tie-break would deterministically starve the last
        # cells every cycle (caught on the first unattended morning ledger —
        # significance/* never sampled at n=10 across 12 cells).
        remaining = cells.transform_values(&:to_i)
        alloc = Hash.new(0)
        n.times do
          open = remaining.select { |_, c| c.positive? }.keys
          break if open.empty?
          cell = open.shuffle.min_by { |k| alloc[k] }
          alloc[cell] += 1
          remaining[cell] -= 1
        end

        claims = alloc.flat_map do |(facet, tier), k|
          scope = candidate_scope
                    .joins("JOIN enliterator_visits sv ON sv.id = enliterator_claims.visit_id")
                    .where("sv.facet = ?", facet)
                    .where("COALESCE(enliterator_claims.tier, 'unknown') = ?", tier)
          scope.order(Arel.sql("random()")).limit(k).includes(:visit, :context, :tendable).to_a
        end
        { claims: claims, allocation: alloc.transform_keys { |f, t| "#{f}/#{t}" } }
      end

      def candidate_scope
        # Never-EXAMINED means no instrument audit — an agent flag must not
        # remove a claim from the examiner's sampling pool (v0.26).
        Enliterator::Claim.live.where(locked: false).where.not(visit_id: nil)
                          .where.not(id: Enliterator::Audit.instrument.select(:claim_id))
      end

      # v0.28: cached accuracy for the hot first-turn path (collection_overview /
      # the accuracy tool). Keyed on the audit set's last write + count — NOT the
      # heartbeat id — because audits are filed out-of-band (human /review, agent
      # flag_claim) between beats; a heartbeat-id key would serve a stale number.
      def accuracy_cached
        key = [ "enliterator-accuracy", maximum(:updated_at)&.to_i, count ]
        Rails.cache.fetch(key, expires_in: 5.minutes) { accuracy }
      end

      # The accuracy report, per facet × tier cell. The EFFECTIVE verdict per
      # claim: the latest HUMAN audit wins over any examiner one (the anchor
      # is the only independent ground truth). HEADLINE = the process rate —
      # audits never age out when their claim is superseded (a live-only rate
      # would let re-tending launder the number); `live` is the secondary
      # stock count. Unverifiable is excluded from the accuracy denominator
      # and reported as its own count.
      def accuracy
        cells = Hash.new { |h, k| h[k] = Hash.new(0) }
        effective_verdicts.each do |claim, verdict|
          facet = claim.visit&.facet || "host"
          tier  = claim.tier.presence || "unknown"
          cell  = cells[[ facet, tier ]]
          cell[:audited] += 1
          cell[verdict.to_sym] += 1
          cell[:live] += 1 if claim.superseded_by_id.nil? && claim.status != "superseded"
        end

        cells.map do |(facet, tier), c|
          decided = c[:supported] + c[:unsupported] + c[:contradicted]
          {
            facet: facet, tier: tier, audited: c[:audited], live: c[:live],
            supported: c[:supported], unsupported: c[:unsupported],
            contradicted: c[:contradicted], unverifiable: c[:unverifiable],
            supported_rate: decided.positive? ? (c[:supported].to_f / decided).round(3) : nil
          }
        end.sort_by { |c| [ c[:facet], c[:tier] ] }
      end

      # The examiner's calibration: among claims with BOTH an examiner and a
      # human audit (unverifiable pairs excluded), BINARY agreement —
      # supported vs defective. Below MIN_AGREEMENT_OVERLAPS the rate is nil
      # (counts always available). `overruled_supported` is the load-bearing
      # line: examiner said supported, the human said defective — the
      # false-supported rate bounds trust in the whole headline.
      def anchor_agreement
        pairs = audit_pairs
        usable = pairs.reject { |e, h| e.verdict == "unverifiable" || h.verdict == "unverifiable" }
        agreements = usable.count { |e, h| e.defective? == h.defective? }
        e_supported = usable.select { |e, _| e.verdict == "supported" }
        {
          overlaps:            usable.size,
          agreements:          agreements,
          rate:                usable.size >= MIN_AGREEMENT_OVERLAPS ? (agreements.to_f / usable.size).round(3) : nil,
          examiner_supported:  e_supported.size,
          overruled_supported: e_supported.count { |_, h| h.defective? },
          matrix:              usable.group_by { |e, h| [ e.verdict, h.verdict ] }.transform_values(&:size)
        }
      end

      def corrected_count
        where.not(corrected_claim_id: nil).count
      end

      # v0.60: THE canonical audit-verdict precedence, id-keyed and batched. For the
      # given claim ids returns `{claim_id => [source, verdict]}` (absent when a claim
      # has no instrument audit): latest row wins UNLESS a human verdict already stands
      # and this row is examiner. Instrument-scoped (agent flags carry no weight, v0.26).
      # The single source of truth for "what does the audit say about this claim" —
      # Claim#warrant and Atlas#audit_verdicts read it. (The private, claim-object-keyed
      # `effective_verdicts` remains the accuracy path — it needs the claim + visit it
      # preloads; both encode the SAME precedence.)
      def effective_verdict_pairs(claim_ids)
        ids = Array(claim_ids).compact
        return {} if ids.empty?

        instrument.where(claim_id: ids).order(:created_at).each_with_object({}) do |a, h|
          next if h[a.claim_id]&.first == "human" && a.source == "examiner"
          h[a.claim_id] = [ a.source, a.verdict ]
        end
      end

      private

      # {claim => effective_verdict} — latest human, else latest examiner.
      # Instrument-scoped: agent flags carry no verdict weight (v0.26).
      def effective_verdicts
        instrument.includes(claim: :visit).order(:created_at).each_with_object({}) do |audit, h|
          current = h[audit.claim]
          # Walk in created order: later rows replace earlier UNLESS a human
          # verdict already stands and this one is examiner.
          next if current&.first == "human" && audit.source == "examiner"
          h[audit.claim] = [ audit.source, audit.verdict ]
        end.transform_values(&:last)
      end

      # [[latest examiner audit, latest human audit], ...] per overlapping claim.
      def audit_pairs
        by_claim = instrument.order(:created_at).group_by(&:claim_id)
        by_claim.filter_map do |_, audits|
          e = audits.select { |a| a.source == "examiner" }.last
          h = audits.select { |a| a.source == "human" }.last
          [ e, h ] if e && h
        end
      end
    end
  end
end
