module Enliterator
  # v0.15: one row = one heartbeat cycle. The model IS the scheduler — the
  # cycle is a record (PROV Activity), so planning, execution, and audit share
  # one identity. `Heartbeat.plan` computes the event-driven work queue (pure
  # read — see Heartbeat::Planner); `Heartbeat.beat!` opens a row (the row is
  # the overlap lock), executes the plan under the token budget, runs the
  # considerer (one heartbeat = one full metabolic cycle: tend → consider),
  # and finalizes the ledger. Every Visit a cycle causes points back here.
  class Heartbeat < ApplicationRecord
    MODES          = %w[sync enqueue].freeze
    OVERLAP_WINDOW = 6.hours
    # A cycle whose first items ALL fail is a misconfiguration, not a workload —
    # abort before burning the budget on it.
    EARLY_FAILURE_LIMIT = 5

    # Raised when an unfinished cycle younger than the window exists. Loud by
    # design: doubled spend through the budget instrument is the one failure
    # the instrument exists to prevent. Pass force: true to override.
    class Overlap < StandardError; end

    has_many :visits, class_name: "Enliterator::Visit", dependent: :nullify

    # An open row younger than the overlap window is a running (or crashed)
    # cycle — beat! refuses to start another without force.
    scope :unfinished, -> { where(finished_at: nil) }

    # Compute the next cycle's work queue — PURE READ, no writes, no network.
    # The standing preview (Status) and the dry-run (PLAN=1) both read this.
    def self.plan(budget: nil)
      Planner.new(budget: budget).plan
    end

    # Run one full cycle. Returns the finalized (or error-stamped) row.
    #
    #   execute: :sync    — tend inline, per-item logged, budget enforced on
    #                       ACTUAL tokens (the cap is a guarantee). The
    #                       supervised default.
    #   execute: :enqueue — TendingVisitJob.perform_later per item; the plan's
    #                       estimates are the only bound. Actuals stay
    #                       derivable via Visit.where(heartbeat_id:).
    def self.beat!(execute: :sync, budget: nil, skip_consider: false, force: false)
      mode = execute.to_s
      raise ArgumentError, "execute must be one of #{MODES.join('/')}" unless MODES.include?(mode)

      open = unfinished.where("started_at > ?", OVERLAP_WINDOW.ago).order(:started_at).last
      if open && !force
        raise Overlap, "heartbeat ##{open.id} is still open (started #{open.started_at.iso8601}) — " \
                       "a running or crashed cycle. Investigate it, or pass force: true / FORCE=1."
      end

      the_plan = plan(budget: budget)
      row = create!(
        started_at:      Time.current,
        mode:            mode,
        budget_tokens:   the_plan.budget,
        planned:         the_plan.to_ledger,
        config_snapshot: config_snapshot,
        warnings:        open ? [ "forced past open heartbeat ##{open.id} (started #{open.started_at.iso8601})" ] : []
      )
      row.execute!(the_plan, skip_consider: skip_consider)
      row
    end

    def self.config_snapshot
      c = Enliterator.configuration
      {
        "heartbeat_budget_tokens"      => c.heartbeat_budget_tokens,
        "heartbeat_change_share"       => c.heartbeat_change_share,
        "heartbeat_neighbor_threshold" => c.heartbeat_neighbor_threshold,
        "stale_after_seconds"          => c.stale_after.to_i,
        "tending_facets"               => Array(c.tending_facets).map(&:to_s),
        "apply_approved_keys"          => c.apply_approved_keys
      }
    end

    def finished? = finished_at.present?

    def planned_count
      (planned || {}).dig("counts")&.values&.sum.to_i
    end

    # ---- execution -----------------------------------------------------------

    # Work the plan, then consider, then finalize. Item failures log and
    # continue; a cycle-level failure (or an all-failures start) records
    # `error` on the row, finalizes, and re-raises — the ledger holds the
    # evidence either way.
    def execute!(plan, skip_consider: false)
      counts = Hash.new { |h, k| h[k] = { "succeeded" => 0, "failed" => 0, "skipped" => 0, "enqueued" => 0 } }
      run_warnings = []

      begin
        work_items!(plan, counts, run_warnings)
        consider!(run_warnings) unless skip_consider
        drain_deficit_check!(run_warnings) if mode == "enqueue"
      rescue => e
        finalize!(counts, run_warnings, error_message: "#{e.class}: #{e.message}")
        raise
      end

      finalize!(counts, run_warnings)
      self
    end

    private

    def work_items!(plan, counts, run_warnings)
      total_failed = 0
      plan.items.each_with_index do |item, i|
        if mode == "sync" && actual_tokens_spent >= budget_tokens
          left = plan.items.size - i
          run_warnings << "budget reached on actuals after #{i} item(s) — #{left} left for the next cycle"
          log("budget reached: #{actual_tokens_spent}/#{budget_tokens} tokens after #{i} item(s); #{left} deferred")
          break
        end

        record = item.record
        if record.nil?
          counts[item.reason]["skipped"] += 1
          run_warnings << "#{item.tendable_type}/#{item.tendable_id} missing — skipped (#{item.lane})"
          next
        end

        begin
          if mode == "sync"
            visit = record.tend!(facet: item.facet, context: item.context,
                                 heartbeat: self, reason: item.reason)
            counts[item.reason]["succeeded"] += 1
            log("[#{i + 1}/#{plan.items.size}] #{item.reason} #{item.lane} " \
                "#{item.tendable_type}/#{item.tendable_id} tier=#{visit.tier} " \
                "conf=#{visit.confidence} spent=#{actual_tokens_spent}/#{budget_tokens}")
          else
            Enliterator::TendingVisitJob.perform_later(record, item.facet, item.context,
                                                       heartbeat_id: id, reason: item.reason)
            counts[item.reason]["enqueued"] += 1
          end
        rescue => e
          counts[item.reason]["failed"] += 1
          total_failed += 1
          log("[#{i + 1}/#{plan.items.size}] #{item.tendable_type}/#{item.tendable_id} FAILED #{e.class}: #{e.message}")
          succeeded = counts.values.sum { |c| c["succeeded"] + c["enqueued"] }
          if succeeded.zero? && total_failed >= EARLY_FAILURE_LIMIT
            raise "first #{EARLY_FAILURE_LIMIT} item(s) all failed (last: #{e.class}: #{e.message}) — " \
                  "aborting the cycle as a misconfiguration, not a workload"
          end
        end
      end
    end

    # The metabolic second half: tend → consider, codified (the standing "wire
    # enliterator:consider AFTER enliterator:tend" guidance made structural).
    # One pass per scope with open requests (root = nil). Never budget-gated —
    # skipping governance because tending was expensive would silently stall
    # convergence. Outcomes land in the `considerer` jsonb; its LLM tokens have
    # no usage surface today (decide returns no usage) — noted, not invented.
    def consider!(run_warnings)
      scopes = Enliterator::Suggestion.pending.distinct.pluck(:context_id)
      return if scopes.empty?

      if mode == "enqueue"
        run_warnings << "enqueue mode: the considerer saw the queue BEFORE this cycle's tends executed (one-cycle lag)"
      end

      outcomes = {}
      scopes.each do |ctx_id|
        ctx = ctx_id && Enliterator::Context.find_by(id: ctx_id)
        key = ctx&.key || "root"
        outcomes[key] = Enliterator::Considerer.new(context: ctx).consider!
        log("considerer #{key}: #{outcomes[key].map { |k, v| "#{k}=#{v}" }.join(' ')}")
      end
      update!(considerer: outcomes)
    end

    # Enqueue mode's queue boundary made visible: if the PREVIOUS enqueue cycle's
    # jobs never ran (Sidekiq down/lagging), its planned work left no visits —
    # each nightly beat would silently re-enqueue the same candidates forever.
    def drain_deficit_check!(run_warnings)
      prev = self.class.where(mode: "enqueue").where.not(finished_at: nil)
                 .where.not(id: id).order(:started_at).last
      return unless prev

      enqueued = (prev.executed || {}).values.sum { |c| c["enqueued"].to_i }
      return if enqueued.zero?
      landed = prev.visits.where(applied: true).count
      return if landed >= enqueued / 2

      run_warnings << "drain deficit: heartbeat ##{prev.id} enqueued #{enqueued} item(s) but only " \
                      "#{landed} visit(s) landed — is the job queue running?"
      log(run_warnings.last)
    end

    def finalize!(counts, run_warnings, error_message: nil)
      update!(
        finished_at:  Time.current,
        executed:     counts,
        tokens_spent: mode == "sync" ? actual_tokens
                                     : { "note" => "enqueue mode — derive via Visit.where(heartbeat_id: #{id})" },
        warnings:     Array(warnings) + run_warnings,
        error:        error_message
      )
      log("cycle #{error_message ? 'ABORTED' : 'finished'}: " \
          "#{counts.map { |r, c| "#{r}=#{c.compact.map { |k, v| "#{k}:#{v}" }.join(',')}" }.join('  ')} " \
          "tokens=#{mode == 'sync' ? actual_tokens_spent : 'enqueued'}#{error_message ? " error=#{error_message}" : ''}")
    end

    # Sync-mode actuals — summed from the visits this cycle stamped (the
    # escalation chain's junior rows included, since every row carries the
    # heartbeat_id). This is what makes the budget a guarantee, not a guess.
    def actual_tokens
      visits.pluck(:tokens).each_with_object({ "input" => 0, "output" => 0, "total" => 0 }) do |t, acc|
        next unless t.is_a?(Hash)
        %w[input output total].each { |k| acc[k] += (t[k] || t[k.to_sym]).to_i }
      end
    end

    def actual_tokens_spent
      actual_tokens["total"]
    end

    def log(msg)
      logger = Enliterator.logger
      logger ? logger.info("[enliterator:heartbeat] #{msg}") : nil
    rescue StandardError
      nil
    end
  end
end
