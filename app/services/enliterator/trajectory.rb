module Enliterator
  # The LONGITUDINAL read of the substrate the engine already stores — does
  # understanding actually COMPOUND across visits? Synopsis answers "what does
  # the collection know"; Trajectory answers "how did this record's knowledge
  # CHANGE, visit over visit" — reconstructed entirely from the provenance the
  # loop writes (Visit.reconciliation, the Claim supersession chain). Pure read,
  # no network, no writes.
  #
  #   Enliterator::Trajectory.state_at(record, time)        # claims live at a moment
  #   Enliterator::Trajectory.for(record)                   # per-facet visit timeline + diffs
  #   Enliterator::Trajectory.compounding_summary(records)  # the experiment rollup
  #
  # Reconstruction rule — a claim is live at time T iff:
  #   created_at <= T
  #   AND NOT (superseded_by_id present AND the superseding claim's created_at <= T)
  #   AND NOT (a DELETE tombstone — status "superseded" with NO superseded_by —
  #            whose updated_at <= T)
  # Locked/host-asserted claims (visit nil) follow the same rule. CAVEAT: a DELETE
  # tombstone records no dedicated deletion timestamp; updated_at stands in for it
  # (adequate under the engine's single-writer tending; a later in-place update of
  # a tombstone would blur it, which the loop never does).
  module Trajectory
    module_function

    # An UPDATE whose new value is essentially the old value restated. Bigram-Dice
    # similarity above this flags `churn: true` — looks like compounding, isn't.
    CHURN_THRESHOLD = 0.85
    VALUE_TRUNCATE  = 160

    # ---- state reconstruction --------------------------------------------

    # The claim set live at `time` (a Time or a Visit, whose created_at is used).
    # Context scoping mirrors the live read: own + ancestors + root (NULL).
    def state_at(record, time, context: nil)
      t = time.respond_to?(:created_at) ? time.created_at : time
      scope = record.enliterator_claims.where("enliterator_claims.created_at <= ?", t)
      scope = scope.where(context_id: context.scope_ids) if context
      claims = scope.includes(:visit).to_a
      by_id  = claims.index_by(&:id)

      claims.select { |c| live_at?(c, t, by_id) }
    end

    # The claim set AFTER a visit's reconcile has been applied. A visit's claims
    # are written moments AFTER the Visit row's created_at (the row opens the
    # pass; reconcile closes it), so `state_at(visit.created_at)` is the state
    # BEFORE the visit — this is the state it left behind. The boundary is the
    # next applied visit on the same facet (its writes haven't happened yet),
    # else now. Timeline steps and the judge both read post-visit states.
    def state_after(record, visit, context: nil)
      boundary = record.enliterator_visits.applied
                   .where(facet: visit.facet)
                   .where("created_at > ?", visit.created_at)
                   .minimum(:created_at)
      state_at(record, boundary ? boundary - 0.001 : Time.current, context: context)
    end

    # ---- the per-record timeline ------------------------------------------

    # Per facet: the ordered APPLIED visits with ops, confidence, the claim state
    # AT that visit (restricted to claims born of that facet's visits), and the
    # diff from the prior visit's state. `facet:` narrows to one; `last:` caps the
    # window (newest kept). Host-asserted claims (visit nil) have no facet and are
    # not part of any facet's timeline — they appear in state_at, not here.
    def for(record, facet: nil, context: nil, last: 6)
      visits = record.enliterator_visits.applied.where(status: "succeeded").order(:created_at)
      visits = visits.where(facet: facet) if facet
      visits = visits.where(context_id: context.scope_ids) if context

      visits.group_by(&:facet).filter_map do |facet_name, vs|
        vs = vs.last(last)
        facet_visit_ids = record.enliterator_visits.where(facet: facet_name).pluck(:id).to_set

        prior_state = nil
        steps = vs.map do |v|
          state = facet_state_after(record, v, facet_visit_ids, context: context)
          step = {
            visit:      v,
            ops:        ops_of(v),
            confidence: v.confidence,
            state:      state,
            diff:       prior_state ? diff_states(prior_state, state) : nil
          }
          prior_state = state
          step
        end

        { facet: facet_name, steps: steps }
      end
    end

    # ---- the experiment rollup ---------------------------------------------

    # Aggregate compounding metrics across `records`, grouped by PASS INDEX (the
    # 1st, 2nd, … applied visit per record+facet): op mix, mean confidence,
    # churn rate among UPDATEs, novel-key (ADD) rate. The shape the experiment
    # report reads.
    def compounding_summary(records, context: nil)
      passes = Hash.new { |h, k| h[k] = { visits: 0, added: 0, updated: 0, deleted: 0, noop: 0, churned: 0, confidences: [] } }

      Array(records).each do |record|
        self.for(record, context: context, last: 50).each do |facet_line|
          facet_line[:steps].each_with_index do |step, i|
            b = passes[i + 1]
            b[:visits] += 1
            ops = step[:ops]
            b[:added]   += ops[:added].size
            b[:updated] += ops[:updated].size
            b[:deleted] += ops[:deleted].size
            b[:noop]    += ops[:noop].size
            b[:confidences] << step[:confidence].to_f if step[:confidence]
            b[:churned] += step[:diff] ? step[:diff].count { |d| d[:kind] == :changed && d[:churn] } : 0
          end
        end
      end

      passes.sort.to_h.transform_values do |b|
        total_ops = b[:added] + b[:updated] + b[:deleted] + b[:noop]
        {
          visits:          b[:visits],
          ops:             b.slice(:added, :updated, :deleted, :noop),
          mean_confidence: b[:confidences].any? ? (b[:confidences].sum / b[:confidences].size).round(3) : nil,
          churn_rate:      b[:updated].positive? ? (b[:churned].to_f / b[:updated]).round(3) : nil,
          novel_rate:      total_ops.positive? ? (b[:added].to_f / total_ops).round(3) : nil
        }
      end
    end

    # ---- internals ---------------------------------------------------------

    def live_at?(claim, t, by_id)
      if claim.superseded_by_id
        superseder = by_id[claim.superseded_by_id] || Enliterator::Claim.find_by(id: claim.superseded_by_id)
        return true if superseder.nil?
        superseder.created_at > t
      elsif claim.status == "superseded"
        claim.updated_at > t   # DELETE tombstone — deletion time ≈ updated_at
      else
        true
      end
    end

    # State AFTER visit V, restricted to claims created by this facet's visits
    # (facet_visit_ids: a Set of visit ids belonging to the facet).
    def facet_state_after(record, visit, facet_visit_ids, context: nil)
      state_after(record, visit, context: context)
        .select { |c| c.visit_id && facet_visit_ids.include?(c.visit_id) }
        .index_by(&:key)
    end

    def ops_of(visit)
      r = visit.reconciliation || {}
      {
        added:   Array(r["added"]   || r[:added]),
        updated: Array(r["updated"] || r[:updated]),
        deleted: Array(r["deleted"] || r[:deleted]),
        noop:    Array(r["noop"]    || r[:noop])
      }
    end

    # Per-key diff between two {key => Claim} states.
    def diff_states(before, after)
      keys = (before.keys + after.keys).uniq.sort
      keys.filter_map do |key|
        old_c, new_c = before[key], after[key]
        if old_c.nil? && new_c
          { key: key, kind: :added, to: render(new_c.value) }
        elsif old_c && new_c.nil?
          { key: key, kind: :deleted, from: render(old_c.value) }
        elsif old_c.id != new_c.id || old_c.value != new_c.value
          sim = similarity(serialize(old_c.value), serialize(new_c.value))
          { key: key, kind: :changed, from: render(old_c.value), to: render(new_c.value),
            similarity: sim.round(3), churn: sim > CHURN_THRESHOLD }
        end
      end
    end

    # Bigram-Dice coefficient — cheap, dependency-free churn heuristic.
    def similarity(a, b)
      return 1.0 if a == b
      ba, bb = bigrams(a), bigrams(b)
      return 0.0 if ba.empty? || bb.empty?
      overlap = 0
      counts = Hash.new(0)
      ba.each { |g| counts[g] += 1 }
      bb.each { |g| (overlap += 1; counts[g] -= 1) if counts[g].positive? }
      (2.0 * overlap) / (ba.size + bb.size)
    end

    def bigrams(s)
      s = s.to_s.downcase.gsub(/\s+/, " ")
      return [] if s.length < 2
      (0..s.length - 2).map { |i| s[i, 2] }
    end

    def serialize(value)
      value.is_a?(String) ? value : value.to_json
    end

    def render(value)
      s = serialize(value)
      s.length > VALUE_TRUNCATE ? "#{s[0, VALUE_TRUNCATE]}…" : s
    end
  end
end
