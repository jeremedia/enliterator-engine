# frozen_string_literal: true

module Enliterator
  # v0.72 — WHAT THE WHOLE POPULATION LOOKS LIKE.
  #
  # The standing audit sampler equalizes count per facet×tier CELL, which is the
  # right design for detecting a garbage tier — and the wrong instrument for
  # per-key truth: a 2,400-claim cell gets audited at 1.4% while two-claim tail
  # cells are audited to exhaustion. Measured on a live collection, the standing
  # authorship rate read .692 where the full population's truth was .986, and
  # per-key rates at n=24 showed no difference where a 10-point gap existed —
  # no statistical power, displayed with three decimal places.
  #
  # The census is the population instrument: it walks EVERY live, engine-derived
  # claim on a facet (optionally one key, one context, one type), renders a
  # grounded verdict per claim with the same blind `Audit::Examiner#verdict_for`
  # the bake-off uses, and reports pooled + per-key rates — split by the host's
  # visibility partition when one is configured, because that split is where
  # population structure hides (.708 visible vs .591 withheld under a .695
  # pooled average, on the collection that motivated this).
  #
  # Bakeoff auditions CANDIDATE readers on records; the census examines the
  # STANDING claim store. Same instrument, different question.
  #
  # WRITES NOTHING by default — verdicts are aggregated in memory and printed.
  # With flag: true it files ONLY defective verdicts (unsupported/contradicted)
  # as `source: "agent"` audits — the v0.26 primitive that is deliberately
  # OUTSIDE the accuracy instrument: an agent flag changes NO accuracy number,
  # leaves the claim in the examiner's sampling pool, and exists to reach a
  # human on /review. Agents flag; humans retract. A census must never file
  # instrument audits: that would starve the nightly sampler of the walked
  # population and let one walk permanently dominate the facet's process rate.
  class Census
    # The examiner resolving to the Null adapter is a CONFIGURATION failure,
    # not weather — a census that "completed" against it would print a table
    # of zero-decided rates and look like an answer (rule 3). Abort loudly.
    class ExaminerUnavailable < StandardError; end

    FLAG_LIMIT_DEFAULT = 50

    def self.run(facet:, **kwargs) = new(facet: facet, **kwargs).run

    # @param facet [String] the facet whose claims are walked
    # @param context [Enliterator::Context, nil] restrict to one context lane
    # @param key [String, nil] restrict to one claim key
    # @param type [String, nil] restrict to one tendable type
    # @param limit [Integer, nil] RANDOM subsample cap (a mini-census; the full
    #   walk is the point — most-recent would be the frontier, not a sample)
    # @param visible [#call, nil] (record) → boolean partition; defaults to
    #   `Enliterator.configuration.census_visibility`; nil ⇒ no split
    # @param flag [Boolean] file defective verdicts as agent audits (capped)
    # @param flag_limit [Integer] cap on filings per run (default 50) — the
    #   /review queue eager-loads its full unreviewed set, so an uncapped bulk
    #   file would weigh every page load; the report prints found vs filed so
    #   the cap is never silent
    # @param examiner [Audit::Examiner] ONE instrument for the whole walk
    def initialize(facet:, context: nil, key: nil, type: nil, limit: nil,
                   visible: nil, flag: false, flag_limit: nil, examiner: nil,
                   progress: nil)
      @facet      = facet.to_s
      @context    = context
      @key        = key.presence
      @type       = type.presence
      @limit      = limit&.to_i&.then { |n| n.positive? ? n : nil }
      @visible    = visible || Enliterator.configuration.census_visibility
      @flag       = !!flag
      @flag_limit = (flag_limit || FLAG_LIMIT_DEFAULT).to_i
      @examiner   = examiner || Enliterator::Audit::Examiner.new
      @progress   = progress
    end

    def run
      started    = Time.current
      population = base_scope.count
      claims     = walk_scope.to_a

      counts   = Hash.new(0)
      abst     = Hash.new(0)
      per_key  = Hash.new { |h, k| h[k] = fresh_bucket }
      split    = @visible ? { visible: Hash.new(0), withheld: Hash.new(0) } : nil
      blank    = 0
      examined = 0
      errors   = []
      defects  = []

      claims.group_by { |c| [ c.tendable_type, c.tendable_id ] }.each_value do |group|
        record = group.first.tendable
        if record.nil?
          errors << "#{group.first.tendable_type}/#{group.first.tendable_id}: tendable missing"
          next
        end

        full = source_error(record, errors) { record.enliterator_text(facet: @facet).to_s }
        next if full.nil?
        if full.strip.empty?
          blank += group.size
          next
        end

        ceiling   = Enliterator.configuration.audit_source_chars.to_i
        truncated = full.length > ceiling
        source    = truncated ? full[0, ceiling] : full
        vis       = @visible ? visibility_of(record, errors) : nil
        next if @visible && vis.nil?   # partition callable failed — errored, skip group

        group.each do |claim|
          begin
            rendered = @examiner.verdict_for(
              facet: @facet, key: claim.key, value: claim.value,
              context: claim.context, source: source, truncated: truncated
            )
            # :unavailable is a RETURN value, not an exception — a config
            # problem, and retrying it 1,400 times is not resilience.
            raise ExaminerUnavailable, "examiner resolves to the Null adapter — configure the gateway (audit_tier / ladder)" if rendered == :unavailable
            next blank += 1 if rendered == :blank_source

            verdict = rendered[:verdict]
            examined += 1
            bucket = per_key[claim.key]
            # v0.72.5: empties (claims of absence) aggregate SEPARATELY —
            # abstention is its own metric, never folded into precision.
            if Enliterator::Claim.blank_value?(claim.value)
              abst[verdict] += 1
              bucket[:abstentions][verdict] += 1
            else
              counts[verdict] += 1
              bucket[:counts][verdict] += 1
              if split
                lane = vis ? :visible : :withheld
                split[lane][verdict] += 1
                bucket[lane][verdict] += 1
              end
            end
            if @flag && Enliterator::Audit::DEFECTIVE.include?(verdict)
              defects << { claim: claim, rendered: rendered, digest: Digest::MD5.hexdigest(full),
                           chars: full.length, truncated: truncated }
            end
            @progress&.call(examined: examined, total: claims.size, claim: claim, verdict: verdict)
          rescue ExaminerUnavailable
            raise
          rescue StandardError => e
            # A 1,400-call walk WILL hit a gateway timeout. One transient
            # failure must not void a multi-hour walk — count it, keep going,
            # print the count (rule 3: the count must print).
            errors << "#{claim.tendable_type}/#{claim.tendable_id} #{claim.key}: #{e.class}: #{e.message[0, 120]}"
          end
        end
      end

      flags = @flag ? file_flags!(defects) : nil

      report(population: population, walked: claims.size, examined: examined,
             blank_source: blank, errors: errors, counts: counts, abst: abst,
             per_key: per_key, split: split, flags: flags,
             elapsed_s: (Time.current - started).round(1))
    end

    private

    # Live, engine-derived (visit-bearing — host assertions are not the model's
    # accuracy), unlocked (locked claims are curator rulings, not the model's).
    # Facet lives on the minting visit, so the walk joins through it.
    def base_scope
      s = Enliterator::Claim.live.where(locked: false).where.not(visit_id: nil)
            .joins("JOIN enliterator_visits sv ON sv.id = enliterator_claims.visit_id")
            .where("sv.facet = ?", @facet)
      s = s.where(context_id: @context.id) if @context
      s = s.where(key: @key) if @key
      s = s.where(tendable_type: @type) if @type
      s
    end

    def walk_scope
      s = base_scope.includes(:context, :tendable)
      # RANDOM subsample, never most-recent — the v0.70 lesson: recency on a
      # converged collection is the pathological frontier, not a sample.
      s = s.order(Arel.sql("random()")).limit(@limit) if @limit
      s
    end

    def fresh_bucket
      b = { counts: Hash.new(0), abstentions: Hash.new(0) }
      if @visible
        b[:visible]  = Hash.new(0)
        b[:withheld] = Hash.new(0)
      end
      b
    end

    def visibility_of(record, errors)
      !!@visible.call(record)
    rescue StandardError => e
      errors << "#{record.class}/#{record.id}: visibility callable: #{e.class}: #{e.message[0, 120]}"
      nil
    end

    def source_error(record, errors)
      yield
    rescue StandardError => e
      errors << "#{record.class}/#{record.id}: enliterator_text: #{e.class}: #{e.message[0, 120]}"
      nil
    end

    # File defective verdicts as agent audits — with the same source stamps
    # `examine!` writes (digest/chars/truncated exist precisely so a later
    # reader can judge what the verdict was rendered against).
    #
    # Idempotent by skip, because audits are append-only and a weekly census on
    # a still-damaged facet must not grow /review's eager-loaded queue forever:
    # a claim already carrying ANY human audit is settled (the human ruled, and
    # /review's queue excludes it permanently — re-filing would be dead rows);
    # a claim already carrying a defective examiner/agent audit with no human
    # answer is already IN the queue. Every skip is counted and printed.
    def file_flags!(defects)
      stats = { found: defects.size, filed: 0, already_flagged: 0, human_settled: 0, over_limit: 0, limit: @flag_limit }
      return stats if defects.empty?

      existing = Enliterator::Audit.where(claim_id: defects.map { |d| d[:claim].id })
                                   .group_by(&:claim_id)
      defects.each do |d|
        rows = existing[d[:claim].id] || []
        next stats[:human_settled]  += 1 if rows.any? { |a| a.source == "human" }
        next stats[:already_flagged] += 1 if rows.any?(&:defective?)
        next stats[:over_limit]     += 1 if stats[:filed] >= @flag_limit

        r = d[:rendered]
        Enliterator::Audit.create!(
          claim:            d[:claim],
          verdict:          r[:verdict],
          rationale:        r[:rationale],
          corrected_value:  r[:corrected_value],
          confidence:       r[:confidence],
          source:           "agent",
          auditor:          "census:#{r[:tier]}:#{r[:model]}",
          source_digest:    d[:digest],
          source_chars:     d[:chars],
          source_truncated: d[:truncated]
        )
        stats[:filed] += 1
      end
      stats
    end

    # `counts`/`supported_rate` (and the visibility lanes) are FILLED claims
    # only — precision. Empties report as `abstained`/`abstention_accuracy`,
    # the separate metric (v0.72.5).
    def report(population:, walked:, examined:, blank_source:, errors:, counts:,
               abst:, per_key:, split:, flags:, elapsed_s:)
      {
        facet: @facet,
        context: @context&.key,
        key: @key, type: @type, limit: @limit,
        population: population, walked: walked, examined: examined,
        blank_source: blank_source, error_count: errors.size, errors: errors,
        counts: counts.sort.to_h,
        supported_rate: Enliterator::Audit.rate(counts),
        abstained: abst.values.sum,
        abstention_counts: abst.sort.to_h,
        abstention_accuracy: Enliterator::Audit.rate(abst),
        visibility: split && {
          visible:  lane_report(split[:visible]),
          withheld: lane_report(split[:withheld])
        },
        per_key: per_key.sort.to_h.transform_values { |b| key_report(b) },
        flags: flags,
        elapsed_s: elapsed_s
      }
    end

    def lane_report(lane_counts)
      { counts: lane_counts.sort.to_h,
        examined: lane_counts.values.sum,
        supported_rate: Enliterator::Audit.rate(lane_counts) }
    end

    def key_report(bucket)
      out = lane_report(bucket[:counts])
      out[:abstained]           = bucket[:abstentions].values.sum
      out[:abstention_counts]   = bucket[:abstentions].sort.to_h
      out[:abstention_accuracy] = Enliterator::Audit.rate(bucket[:abstentions])
      if @visible
        out[:visible]  = lane_report(bucket[:visible])
        out[:withheld] = lane_report(bucket[:withheld])
      end
      out
    end
  end
end
