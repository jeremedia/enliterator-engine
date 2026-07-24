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
    # v0.23: an unfinished row whose last sign of life (pulse_at) is older
    # than this is an ORPHAN — its process died (restart, kill) without a
    # chance to stamp the ledger. Generous against the slowest legitimate
    # gap (one quality-tier call under the configured gateway timeout).
    REAP_AFTER = 15.minutes

    # Raised when an unfinished cycle younger than the window exists. Loud by
    # design: doubled spend through the budget instrument is the one failure
    # the instrument exists to prevent. Pass force: true to override.
    class Overlap < StandardError; end

    # v0.23: raised inside a cycle's own loops when its row has been reaped
    # by another process — the zombie case: a gracefully-draining old server
    # process whose thread keeps tending after a reaper declared it dead.
    # Standing down stops the spend; the row already ended honestly.
    class StoodDown < StandardError; end

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
      row, the_plan = open!(mode: execute, budget: budget, force: force)
      row.execute!(the_plan, skip_consider: skip_consider)
      row
    end

    # Open a cycle: validate, take the lock, plan, create the row — and return
    # [row, plan] so the caller chooses HOW to execute (inline via execute!,
    # or in the background via execute_async! — the v0.16 trigger page).
    #
    # The check→plan→create sequence runs inside a transaction holding a
    # Postgres advisory lock: two concurrent triggers (two browser tabs, a
    # button and a rake) would otherwise BOTH pass the unfinished-row check
    # during the seconds the plan scan takes, and both open cycles — doubled
    # spend, the exact failure this instrument exists to prevent. The engine
    # is Postgres-only (pgvector), so the lock costs nothing and needs no
    # migration. `Overlap` raises synchronously, before any row exists.
    # v-next: `plan:` injects a directed plan (Heartbeat.pulse) instead of
    # computing the change-envelope plan — the ONE seam that turns a beat into a
    # pulse. nil ⇒ today's exact path (the change-envelope Planner), so a
    # non-pulse caller is byte-identical.
    def self.open!(mode: :sync, budget: nil, force: false, plan: nil)
      mode = mode.to_s
      raise ArgumentError, "mode must be one of #{MODES.join('/')}" unless MODES.include?(mode)

      transaction do
        connection.execute("SELECT pg_advisory_xact_lock(hashtext('enliterator_heartbeat'))")

        # v0.23: bury the dead first — an orphaned row (process killed
        # mid-cycle) must not block a new beat for the rest of the window.
        reap_orphans!

        open = unfinished.where("started_at > ?", OVERLAP_WINDOW.ago).order(:started_at).last
        if open && !force
          raise Overlap, "heartbeat ##{open.id} is still open (started #{open.started_at.iso8601}) — " \
                         "a running or crashed cycle. Investigate it, or pass force: true / FORCE=1."
        end

        the_plan = plan || self.plan(budget: budget)
        row = create!(
          started_at:      Time.current,
          mode:            mode,
          trigger:         plan ? "pulse" : "scheduled",
          budget_tokens:   the_plan.budget,
          planned:         the_plan.to_ledger,
          config_snapshot: config_snapshot,
          warnings:        open ? [ "forced past open heartbeat ##{open.id} (started #{open.started_at.iso8601})" ] : []
        )
        [ row, the_plan ]
      end
    end

    # v0.23: stamp every orphaned row — unfinished, with no sign of life for
    # REAP_AFTER. The COALESCE covers pre-v0.23 rows (no pulse_at; updated_at
    # = their last phase stamp). Returns the reaped rows. Called from open!
    # (a dead row must not block the next beat) and the monitor page (the UI
    # heals on view).
    def self.reap_orphans!
      unfinished.where("COALESCE(pulse_at, updated_at, started_at) < ?", REAP_AFTER.ago)
                .order(:id).map(&:reap!)
    end

    # Unfinished with no sign of life past the threshold — reapable. The
    # pulse endpoint uses this so a WATCHED monitor self-heals: the poll
    # that finds the row orphaned stamps it, and the page resolves without
    # anyone reloading.
    def orphaned?
      !finished? && (pulse_at || updated_at || started_at) < REAP_AFTER.ago
    end

    # The honest ending for a cycle whose process died: finished_at = the
    # last sign of life, the death phase named, and `executed` RECONSTRUCTED
    # from the visit record — the ledger heals from its own provenance.
    def reap!
      last_life  = pulse_at || updated_at || started_at
      died_in    = phase.presence || "unknown (pre-v0.23 row)"
      reconstructed = Hash.new { |h, k| h[k] = { "succeeded" => 0, "failed" => 0, "skipped" => 0, "enqueued" => 0 } }
      visits.group(:reason, :status).count.each do |(reason, status), n|
        reconstructed[reason || "unknown"][status] = n if reconstructed[reason || "unknown"].key?(status)
      end
      update!(
        finished_at:  last_life,
        phase:        nil,
        executed:     reconstructed,
        tokens_spent: mode == "sync" ? actual_tokens
                                     : { "note" => "enqueue mode — derive via Visit.where(heartbeat_id: #{id})" },
        error:        "orphaned in phase '#{died_in}' — the process ended mid-cycle " \
                      "(last sign of life #{last_life.iso8601}); executed counts reconstructed from visits"
      )
      log("reaped: orphaned in '#{died_in}', last life #{last_life.iso8601}, " \
          "#{visits.count} visit(s) on the record")
      self
    end

    def self.config_snapshot
      c = Enliterator.configuration
      snap = {
        "heartbeat_budget_tokens"      => c.heartbeat_budget_tokens,
        "heartbeat_change_share"       => c.heartbeat_change_share,
        "heartbeat_neighbor_threshold" => c.heartbeat_neighbor_threshold,
        "stale_after_seconds"          => c.stale_after.to_i,
        "tending_facets"               => Array(c.tending_facets).map(&:to_s),
        "apply_approved_keys"          => c.apply_approved_keys
      }
      # Shape flags stamped ONLY when adopted — a non-adopter's ledger rows
      # stay byte-identical (the snapshot is stored per cycle).
      snap["collection_tendable"]   = c.collection_tendable.to_s if c.collection_tendable
      snap["default_reading_scope"] = c.default_reading_scope.to_s if c.default_reading_scope
      snap
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
        sync_topology!(run_warnings)     # gates + pulses INTERNALLY — no topology ⇒ no phase ⇒ trace byte-identical
        reconcile_charter!(run_warnings) # same discipline: no collection_tendable ⇒ no phase
        pulse!("survey")      ; survey_phase!(run_warnings)
        pulse!("work")        ; work_items!(plan, counts, run_warnings)
        pulse!("considerer")  ; consider!(run_warnings) unless skip_consider
        pulse!("conservator") ; conserve! unless skip_consider
        pulse!("audit")       ; audit_phase!(run_warnings)
        pulse!("finalize")
        drain_deficit_check!(run_warnings) if mode == "enqueue"
      rescue StoodDown => e
        # The row was reaped by another process — it already ended honestly;
        # stamping anything now would overwrite the reaper's record.
        log("standing down: #{e.message}")
        raise
      rescue => e
        # v0.41.1: transient bedrock unavailability anywhere in the cycle (expired
        # token OR timeout/connection) is a PAUSE, not a fault — finish CLEAN (no
        # error stamp, no re-raise, exit 0) so the deferred work simply resumes on
        # the next beat. This is the backstop; the phases defer in place where they
        # can (work_items!, consider!). Every other error stays fatal as before.
        if Enliterator::Adapters::LLM::Bedrock.unavailable?(e)
          run_warnings << "bedrock unavailable mid-cycle — finished early; deferred work resumes " \
                          "on the next beat (transient; re-run `aws sso login` if SSO expired)"
          log(run_warnings.last)
          finalize!(counts, run_warnings)
          return self
        end
        finalize!(counts, run_warnings, error_message: "#{e.class}: #{e.message}")
        raise
      end

      finalize!(counts, run_warnings)
      self
    end

    # Execute the cycle in a background THREAD (the v0.16 trigger page) and
    # return the Thread. Deliberately not ActiveJob: a dead worker would make
    # the button a silent no-op, and the in-process thread works in every
    # host. Trade-offs, accepted and documented: while the cycle runs, the
    # executor's running share makes dev code-reload WAIT (minutes), and the
    # thread holds one AR connection from the pool. NOT
    # `permit_concurrent_loads` — that permits loads, not the unload a
    # reloader needs, and nothing here joins another thread.
    #
    # Hardening: execute! already records cycle errors on the row and
    # re-raises; the outer rescue covers the one silent path left — a failure
    # of finalize! itself (or anything before execute!) — with a best-effort
    # row stamp via update_columns, so an open row can never just stop moving
    # with no explanation. Thread#report_on_exception stays true as backstop.
    def execute_async!(plan, skip_consider: false)
      thread = Thread.new do
        Rails.application.executor.wrap do
          execute!(plan, skip_consider: skip_consider)
        end
      rescue => e
        Enliterator.logger&.error("[enliterator:heartbeat] async cycle ##{id} died: #{e.class}: #{e.message}")
        begin
          update_columns(finished_at: Time.current, error: "#{e.class}: #{e.message}") if reload.finished_at.nil?
        rescue StandardError
          nil
        end
      end
      thread.name = "enliterator-heartbeat-#{id}"
      thread
    end

    private

    # v0.56: derive/reconcile the per-whole Contexts from the declared topology
    # before the shelf-read. The gate is a pure in-memory config check that runs
    # BEFORE any pulse! — a topology-less host's phase trace (which the reaper
    # reads) stays byte-identical. Fail-SOFT per whole (Sync fail_soft: true):
    # one bad slug becomes a ledger warning, never a halted collection.
    def sync_topology!(run_warnings)
      topo = Enliterator.configuration.topology
      return if topo.nil? || !topo.declares_wholes?

      pulse!("topology")
      result = Enliterator::Topology::Sync.run!(topology: topo, fail_soft: true)
      result.warnings.each { |w| run_warnings << "topology: #{w}" }
      log("topology: #{result.summary}")
    rescue StoodDown
      raise
    rescue => e
      # The sync must never kill the tending cycle — record and continue.
      run_warnings << "topology sync failed: #{e.class}: #{e.message}"
      log(run_warnings.last)
    end

    # v0.57: keep the charter's gaps honest each cycle — open a lacuna per
    # untold identity field on the collection tendable, close told ones. The
    # gate is a pure config check BEFORE pulse! (non-adopter phase trace stays
    # byte-identical); a configured-but-unseeded collection record is the one
    # state that must be LOUD here (the ledger is its channel — surfaces just
    # go silent). Fail-soft: identity bookkeeping never halts tending. Sibling
    # to sync_topology!, NOT inside it — charter-without-topology is legal.
    def reconcile_charter!(run_warnings)
      name = Enliterator.configuration.collection_tendable
      return if name.blank?

      pulse!("charter")
      if Enliterator::Charter.record.nil?
        run_warnings << "charter: collection_tendable configured but no #{name} row exists — " \
                        "create it, then rake enliterator:charter"
        log(run_warnings.last)
        return
      end
      result = Enliterator::Charter.reconcile_gaps!
      log("charter: gaps opened/refreshed=#{result[:opened]} closed=#{result[:closed]}")
    rescue StoodDown
      raise
    rescue => e
      run_warnings << "charter reconcile failed: #{e.class}: #{e.message}"
      log(run_warnings.last)
    end

    # v0.17: the per-cycle shelf-read. Time-boxed (probes are column reads —
    # the bound is wall-clock, not tokens); never-surveyed first, then stalest.
    # Skipped silently when no probes are registered (a host that never adopted
    # condition isn't omitting anything; SPEC documents the gate).
    def survey_phase!(run_warnings)
      return unless Enliterator::Condition.probes_registered?

      budget_ms = Enliterator.configuration.heartbeat_survey_budget_ms.to_i
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stats = { "surveyed" => 0, "untendable" => 0, "degraded" => 0 }

      loop do
        pulse!("survey")
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
        break if elapsed_ms >= budget_ms
        batch = Enliterator::Condition.survey_due(limit: 2_000)
        break if batch.empty?

        Enliterator::Condition.survey_batch!(batch).each do |v|
          stats["surveyed"]   += 1
          stats["untendable"] += 1 if v[:band] == :untendable
          stats["degraded"]   += 1 if v[:band] == :degraded
        end
        break if batch.size < 2_000   # the shelf is fully read
      end

      stats["duration_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      update!(survey: stats)
      log("survey: #{stats.map { |k, v| "#{k}=#{v}" }.join(' ')}")
    rescue => e
      raise if e.is_a?(StoodDown)   # a reaped row stands down, never continues
      # The survey must never kill the tending cycle — record and continue.
      run_warnings << "survey phase failed: #{e.class}: #{e.message}"
      log(run_warnings.last)
    end

    def work_items!(plan, counts, run_warnings)
      total_failed = 0
      bedrock_deferred = 0
      plan.items.each_with_index do |item, i|
        stand_down_check!
        pulse!("work")
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

        # v0.17: the execution-time condition gate — the plan was frozen at
        # open!, and this cycle's own survey may have condemned a planned
        # record since. One indexed read beats an LLM call on an unreadable
        # source.
        if condition_untendable?(item)
          counts[item.reason]["skipped"] += 1
          log("[#{i + 1}/#{plan.items.size}] #{item.tendable_type}/#{item.tendable_id} skipped — untendable at execution (condition)")
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
          # v0.41.1: transient bedrock unavailability (an expired token OR a
          # gateway timeout) is a PAUSE, not a failure — defer this item (it stays
          # on the frontier, untended, with no Visit) so the next beat resumes it.
          # The "deferred" tally is added LAZILY (only on a real deferral) so a
          # cycle with none is byte-identical, and a deferral never counts toward
          # total_failed — a transient outage cannot trip the abort below.
          if Enliterator::Adapters::LLM::Bedrock.unavailable?(e)
            counts[item.reason]["deferred"] = counts[item.reason].fetch("deferred", 0) + 1
            bedrock_deferred += 1
            log("[#{i + 1}/#{plan.items.size}] #{item.tendable_type}/#{item.tendable_id} DEFERRED — bedrock unavailable (#{e.class})")
            next
          end
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
      if bedrock_deferred.positive?
        run_warnings << "bedrock unavailable — #{bedrock_deferred} item(s) deferred to the next beat " \
                        "(transient: SSO expiry or gateway timeout); re-run `aws sso login` if the token lapsed"
        log(run_warnings.last)
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
        stand_down_check!
        pulse!("considerer")
        ctx = ctx_id && Enliterator::Context.find_by(id: ctx_id)
        key = ctx&.key || "root"
        begin
          outcomes[key] = Enliterator::Considerer.new(context: ctx).consider!
          log("considerer #{key}: #{outcomes[key].map { |k, v| "#{k}=#{v}" }.join(' ')}")
        rescue => e
          # v0.41.1: transient bedrock unavailability (expired token OR timeout)
          # holds THIS scope for the next beat — scopes already considered stay
          # saved (the update! below still runs) and the cycle finishes clean.
          # Any other error is a real fault and still propagates to the fatal path.
          raise if e.is_a?(StoodDown)
          raise unless Enliterator::Adapters::LLM::Bedrock.unavailable?(e)
          run_warnings << "considerer #{key}: bedrock unavailable — held for the next beat (transient; re-run `aws sso login` if SSO expired)"
          log(run_warnings.last)
        end
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

    # v0.23: every phase boundary and every loop iteration touches the row —
    # pulse_at is the liveness signal the reaper and the stall banner read,
    # in phases that produce visits and phases that don't alike.
    # update_columns: no callbacks, no updated_at churn, one cheap UPDATE.
    def pulse!(phase_name)
      update_columns(pulse_at: Time.current, phase: phase_name)
    end

    # v0.23: the zombie check — if another process reaped this row (stamped
    # error), this thread is a ghost of a dead cycle and must stop spending.
    # One indexed pick per LLM call; trivial next to the call itself.
    def stand_down_check!
      reaped = self.class.where(id: id).pick(:error)
      return unless reaped
      raise StoodDown, "cycle ##{id} was reaped by another process (#{reaped[0, 80]}) — standing down"
    end

    def finalize!(counts, run_warnings, error_message: nil)
      update!(
        finished_at:  Time.current,
        pulse_at:     Time.current,
        phase:        nil,
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

    # v0.17: the conservator's pass — diagnosis + treatment proposals over the
    # condition piles (the Considerer pattern; its own delta gate skips the
    # LLM when nothing changed). Only meaningful once a survey has run.
    # Outcome rides the considerer jsonb under "conservator".
    def conserve!
      return unless condition_adopted?
      outcome = Enliterator::Conservator.new.assess!
      update!(considerer: (considerer || {}).merge("conservator" => outcome))
      log("conservator: #{outcome.map { |k, v| "#{k}=#{v}" }.join(' ')}")
    end

    # v0.18: the quality-review ride-along — examine a stratified sample of
    # claims each cycle. DEFAULT 0 = OFF (setting heartbeat_audit_sample
    # non-zero IS the adoption act; quality-tier spend must never start on a
    # gem upgrade). Count-bounded; audit spend is OUTSIDE the tending token
    # budget (named in SPEC — the budget guarantee covers tending only).
    # Failure semantics mirror the survey: a phase failure warns and the
    # cycle continues; a per-claim failure is counted and the claim re-enters
    # the pool next cycle. A Null adapter is a VISIBLE skip — a standing
    # instrument must never go quiet (the v0.5 lesson).
    def audit_phase!(run_warnings)
      n = Enliterator.configuration.heartbeat_audit_sample.to_i
      return if n <= 0

      sample = Enliterator::Audit.sample(n)
      if sample[:claims].empty?
        update!(audits: { "examined" => 0, "note" => "no unaudited claims in the pool" })
        return
      end

      examiner = Enliterator::Audit::Examiner.new
      stats = Hash.new(0)
      sample[:claims].each do |claim|
        stand_down_check!
        pulse!("audit")
        outcome = begin
          examiner.examine!(claim, heartbeat: self)
        rescue => e
          log("audit of claim ##{claim.id} FAILED #{e.class}: #{e.message}")
          :failed
        end
        case outcome
        when Enliterator::Audit then stats[outcome.verdict] += 1
        when :unavailable
          stats["skipped_null_adapter"] += 1
          break   # every remaining call would skip identically — say it once
        else stats["skipped_#{outcome}"] += 1
        end
      end

      examined = stats.slice(*Enliterator::Audit::VERDICTS).values.sum
      payload = { "examined" => examined, "allocation" => sample[:allocation] }.merge(stats)
      update!(audits: payload)
      if stats["skipped_null_adapter"].positive?
        run_warnings << "audit phase: examiner unavailable (Null adapter) — no verdicts this cycle"
      end
      log("audit: #{payload.map { |k, v| "#{k}=#{v}" }.join(' ')}")
    rescue => e
      raise if e.is_a?(StoodDown)   # a reaped row stands down, never continues
      run_warnings << "audit phase failed: #{e.class}: #{e.message}"
      log(run_warnings.last)
    end

    def condition_untendable?(item)
      return false unless condition_adopted?
      Enliterator::Measure.where(tendable_type: item.tendable_type, tendable_id: item.tendable_id,
                                 name: Enliterator::Condition::ROLLUP, score: 0.0).exists?
    end

    def condition_adopted?
      return @condition_adopted if defined?(@condition_adopted)
      @condition_adopted = Enliterator::Condition.adopted?
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
