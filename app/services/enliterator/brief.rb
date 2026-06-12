module Enliterator
  # v0.27: the Brief — "how did last night's tending go?" in one read.
  #
  # The collection already keeps perfect records of its own activity: heartbeat
  # ledger rows, the immutable Visit history (with errors on the failures),
  # the governance tables. But answering the morning question meant composing
  # an ad-hoc query every time — re-deriving the same joins, forgetting the
  # same corners (did the considerer move anything? did a reading abort?).
  # The Brief is that composition, written once: a time-windowed digest of
  # everything that happened since you last looked.
  #
  # It deliberately does NOT replace Report.summary (the per-facet health
  # rollup / smoke alarm — depth over one dimension). The Brief is breadth
  # over a window: cycles, work, failures with their reasons, deep-read
  # sessions, governance motion. Read the Brief first; reach for
  # Report.summary when a number in it looks wrong.
  #
  #   Enliterator::Brief.report                  # last 12 hours
  #   Enliterator::Brief.report(since: 2.days)   # a Duration reads as "ago"
  #   Enliterator::Brief.report(since: Time.parse("2026-06-11 17:00"))
  #
  # Pure read — no network, no gateway, no cache writes. Surfaced as
  # `rake enliterator:brief` and the MCP tool `recent_activity`.
  module Brief
    module_function

    DEFAULT_WINDOW = 12 * 3600   # seconds; "overnight" with margin
    FAILURE_SAMPLE = 10          # bounded, like every engine payload
    ERROR_MAX      = 200         # chars of each failure's error text

    # @param since [Time, ActiveSupport::Duration, nil] window start; a
    #   Duration (e.g. 12.hours) reads as "ago". Default: the last 12 hours.
    # @return [Hash] see the section builders below for the shape.
    def report(since: nil)
      start = window_start(since)
      rows  = visit_rows(start)

      {
        window:     { since: start, hours: ((Time.current - start) / 3600.0).round(1) },
        headline:   headline(rows, start),
        heartbeats: heartbeats(start),
        visits:     visit_rollup(rows),
        failures:   failures(start),
        readings:   readings(rows),
        governance: governance(start),
        embeddings: { written: Enliterator::Embedding.where("updated_at > ?", start).count }
      }
    end

    # ---- sections ------------------------------------------------------------

    # One line a human (or an agent) can relay verbatim.
    def headline(rows, start)
      statuses = rows.group_by { |r| r[:status] }.transform_values(&:size)
      failed   = statuses["failed"].to_i
      beats    = Enliterator::Heartbeat.where("started_at > ?", start)
      aborted  = beats.count { |b| b.error.present? }

      parts = []
      parts << "#{beats.size} heartbeat#{'s' unless beats.size == 1}#{" (#{aborted} aborted)" if aborted.positive?}"
      parts << "#{rows.size} visit#{'s' unless rows.size == 1}#{" (#{failed} failed)" if failed.positive?}"
      deep = rows.count { |r| r[:reason] == "deep_read" }
      parts << "#{deep} deep-read visit#{'s' unless deep == 1}" if deep.positive?
      parts << "#{delimited(rows.sum { |r| r[:tokens] })} tokens"
      parts.join(" · ")
    end

    # The ledger rows, compacted: what each cycle planned, what it executed,
    # what it spent, and anything it shouted about.
    def heartbeats(start)
      Enliterator::Heartbeat.where("started_at > ?", start).order(:started_at).map do |hb|
        executed = (hb.executed || {}).values.each_with_object(Hash.new(0)) do |counts, acc|
          counts.each { |status, n| acc[status] += n.to_i if n.to_i.positive? }
        end
        {
          at:          hb.started_at,
          finished_at: hb.finished_at,
          mode:        hb.mode,
          planned:     hb.planned_count,
          executed:    executed,
          tokens:      hb.tokens_spent.is_a?(Hash) ? hb.tokens_spent["total"].to_i : 0,
          warnings:    Array(hb.warnings),
          error:       hb.error
        }.compact
      end
    end

    def visit_rollup(rows)
      by_facet = Hash.new { |h, k| h[k] = Hash.new(0) }
      rows.each { |r| by_facet[r[:facet]][r[:status]] += 1 }
      {
        total:     rows.size,
        by_facet:  by_facet.transform_values { |v| v.sort.to_h },
        by_tier:   tally(rows, :tier),
        by_reason: tally(rows, :reason),
        tokens:    rows.sum { |r| r[:tokens] }
      }
    end

    # Every failure carries its error on the Visit row (rule 3: no silent
    # failures) — the Brief surfaces them instead of making you grep a log.
    def failures(start)
      scope  = Enliterator::Visit.where("created_at > ?", start).where(status: "failed")
      sample = scope.order(created_at: :desc).limit(FAILURE_SAMPLE).map do |v|
        {
          at:     v.created_at,
          facet:  v.facet,
          tier:   v.tier,
          record: "#{v.tendable_type}/#{v.tendable_id}",
          error:  v.error.to_s[0, ERROR_MAX].presence
        }.compact
      end
      { count: scope.count, sample: sample, truncated: scope.count > FAILURE_SAMPLE }
    end

    # Deep-read activity (v0.25): part reads roll up to the records they
    # belong to — the librarian sessions, not the page turns. Counts are
    # DISTINCT (a part, a record-facet) — escalation chains write junior AND
    # senior visit rows, and counting rows would report a synthesis twice.
    def readings(rows)
      deep = rows.select { |r| r[:reason] == "deep_read" }
      part_rows, record_rows = deep.partition { |r| r[:tendable_type] == "Enliterator::Part" }

      parents = Enliterator::Part.where(id: part_rows.map { |r| r[:tendable_id] }.uniq)
                                 .distinct.pluck(:record_type, :record_id)
      synthesized = record_rows.map { |r| [ r[:tendable_type], r[:tendable_id] ] }.uniq

      {
        records:      (parents.map { |t, i| [ t, i.to_s ] } | synthesized.map { |t, i| [ t, i.to_s ] }).size,
        parts_read:   part_rows.select { |r| r[:status] == "succeeded" }.map { |r| r[:tendable_id] }.uniq.size,
        parts_failed: part_rows.select { |r| r[:status] == "failed" }.map { |r| r[:tendable_id] }.uniq.size,
        syntheses:    record_rows.select { |r| r[:status] == "succeeded" }
                                 .map { |r| [ r[:tendable_type], r[:tendable_id], r[:facet] ] }.uniq.size,
        tokens:       deep.sum { |r| r[:tokens] }
      }
    end

    # Governance motion: what the loops put in front of the curator (or moved
    # past them) during the window. Suggestions and audits are append-only, so
    # created_at IS the event; proposed terms mutate in place (pressure,
    # verdicts), so updated_at reads as "moved".
    def governance(start)
      {
        suggestions: Enliterator::Suggestion.where("created_at > ?", start).group(:status).count.sort.to_h,
        term_motion: Enliterator::ProposedTerm.where("updated_at > ?", start)
                                              .group(:recommended_decision).count
                                              .transform_keys { |k| k || "open" }.sort.to_h,
        audits:      Enliterator::Audit.where("created_at > ?", start)
                                       .group(:source, :verdict).count
                                       .each_with_object({}) { |((src, verdict), n), acc|
                                         (acc[src] ||= {})[verdict] = n
                                       }
      }
    end

    # ---- internals -----------------------------------------------------------

    def window_start(since)
      case since
      when nil                        then Time.current - DEFAULT_WINDOW
      when ActiveSupport::Duration    then Time.current - since
      else                                 since.to_time
      end
    end

    # One pluck feeds headline, rollup, and readings — the Visit table is the
    # busiest in the engine; read it once.
    def visit_rows(start)
      Enliterator::Visit.where("created_at > ?", start)
                        .pluck(:facet, :status, :tier, :reason, :tendable_type, :tendable_id, :tokens)
                        .map do |facet, status, tier, reason, ttype, tid, tokens|
        { facet: facet, status: status, tier: tier, reason: reason,
          tendable_type: ttype, tendable_id: tid,
          tokens: tokens.is_a?(Hash) ? tokens["total"].to_i : 0 }
      end
    end

    def tally(rows, key)
      rows.group_by { |r| r[key] || "—" }.transform_values(&:size).sort.to_h
    end

    def delimited(n) = ActiveSupport::NumberHelper.number_to_delimited(n)
  end
end
