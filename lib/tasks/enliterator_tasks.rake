# Enliterator scheduled tending walk.
#
# For every registered tendable model and every configured facet, enqueue a
# TendingVisitJob for up to `tend_batch_size` records whose newest succeeded
# visit is older than `stale_after` (or that have never succeeded). Hosts wire
# this to their scheduler (HSDL: sidekiq-cron; others: solid_queue recurring).
#
#   bin/rails enliterator:tend
#
namespace :enliterator do
  desc "Enqueue tending visits for stale/untended records (per model, per facet)"
  task tend: :environment do
    config  = Enliterator.configuration
    facets = Array(config.tending_facets)
    batch   = config.tend_batch_size
    cutoff  = Time.current - config.stale_after
    logger  = Enliterator.logger

    log = ->(msg) { logger ? logger.info("[enliterator:tend] #{msg}") : puts("[enliterator:tend] #{msg}") }

    total_enqueued = 0

    Enliterator.tendable_models.each do |model|
      type_name = model.name

      facets.each do |facet|
        facet = facet.to_s

        # Tendable ids that are FRESH for this facet: their newest succeeded
        # visit finished at or after the cutoff. Everything else (stale or never
        # succeeded) is a candidate. tendable_id is stored as a string, so cast
        # the host PK to text for the comparison (works for bigint and uuid PKs).
        fresh_ids =
          Enliterator::Visit
            .where(tendable_type: type_name, facet: facet, status: "succeeded")
            .where("finished_at >= ?", cutoff)
            .distinct
            .pluck(:tendable_id)

        pk    = model.primary_key
        scope = model.all
        unless fresh_ids.empty?
          pk_sql = "CAST(#{model.quoted_table_name}.#{model.connection.quote_column_name(pk)} AS TEXT)"
          scope  = scope.where("#{pk_sql} NOT IN (?)", fresh_ids)
        end

        # Pull one extra to detect whether the batch cap truncated the candidates.
        candidates = scope.limit(batch + 1).to_a
        capped     = candidates.size > batch
        candidates = candidates.first(batch)

        candidates.each do |record|
          Enliterator::TendingVisitJob.perform_later(record, facet)
        end

        enqueued = candidates.size
        total_enqueued += enqueued

        note = capped ? " (cap #{batch} hit — more stale records remain for this model/facet)" : ""
        log.call("#{type_name} / #{facet}: enqueued #{enqueued}#{note}")
      end
    end

    log.call("done — enqueued #{total_enqueued} tending visit(s) across #{Enliterator.tendable_models.size} model(s) and #{facets.size} facet(s)")
  end

  # The tending rollup / smoke alarm. Prints per-facet Visit health: status mix,
  # adapter/model mix (a `null` model means a misconfigured run wrote phantom
  # "succeeded" visits — flagged loudly), escalation + empty-final rates, confidence
  # buckets, required_unmet count, and token spend.
  #
  #   bin/rails enliterator:status
  #   SINCE=7 bin/rails enliterator:status         # last 7 days
  #   FACET=authorship bin/rails enliterator:status
  desc "Per-facet tending health rollup (status, adapter mix, rates, spend). SINCE=days FACET=name"
  task status: :environment do
    logger = Enliterator.logger
    log = ->(msg) { logger ? logger.info("[enliterator:status] #{msg}") : puts(msg) }

    since  = ENV["SINCE"].present? ? ENV["SINCE"].to_i.days : nil
    facet = ENV["FACET"].presence
    report = Enliterator::Report.summary(since: since, facet: facet)

    if report.empty?
      log.call("No tending visits found#{facet ? " for facet #{facet}" : ''}#{since ? " in the last #{ENV['SINCE']}d" : ''}.")
      next
    end

    report.sort.each do |name, b|
      log.call("── facet: #{name} ── #{b[:total]} visit(s)")
      log.call("   status:    #{b[:status].sort.map { |k, v| "#{k}=#{v}" }.join('  ')}")

      adapters = b[:adapter_mix].sort.map { |k, v| "#{k}=#{v}" }.join("  ")
      null_n = b[:adapter_mix]["null"].to_i
      warn = null_n.positive? ? "   <-- WARNING: null adapter ran #{null_n} visit(s) (no LLM called)" : ""
      log.call("   adapters:  #{adapters}#{warn}")

      log.call("   tiers:     #{b[:tier_mix].sort.map { |k, v| "#{k}=#{v}" }.join('  ')}")
      log.call("   escalation_rate=#{b[:escalation_rate]}  empty_final_rate=#{b[:empty_final_rate]}  required_unmet=#{b[:required_unmet]}")
      log.call("   confidence: #{b[:confidence].sort.map { |k, v| "#{k}=#{v}" }.join('  ')}")
      tokens = b.dig(:spend, :tokens) || {}
      log.call("   tokens:    in=#{tokens['input'].to_i} out=#{tokens['output'].to_i} total=#{tokens['total'].to_i}")
    end
  end

  # The event-driven heartbeat (v0.15) — one full metabolic cycle: plan →
  # tend (change-triggered + frontier + safety-net sweep, budget-capped) →
  # consider → ledger. Default is SYNC (per-item logged, budget enforced on
  # actual tokens — the supervised mode); production opts into ENQUEUE=1
  # deliberately. PLAN=1 prints the work queue and the frontier horizon
  # without executing anything.
  #
  #   bin/rails enliterator:heartbeat                      # sync cycle at the configured budget
  #   PLAN=1 bin/rails enliterator:heartbeat               # dry-run: print the plan + horizon
  #   BUDGET=30000 bin/rails enliterator:heartbeat         # supervised small cycle
  #   ENQUEUE=1 bin/rails enliterator:heartbeat            # enqueue TendingVisitJobs instead
  #   FORCE=1 ...                                          # override the overlap lock (recorded)
  #   SKIP_CONSIDER=1 ...                                  # host schedules the considerer separately
  desc "Run one heartbeat cycle (plan → tend → consider → ledger). BUDGET= PLAN=1 ENQUEUE=1 FORCE=1 SKIP_CONSIDER=1"
  task heartbeat: :environment do
    logger = Enliterator.logger
    log = ->(msg) { logger ? logger.info("[enliterator:heartbeat] #{msg}") : puts(msg) }
    budget = ENV["BUDGET"].presence&.to_i

    if ENV["PLAN"].present?
      plan = Enliterator::Heartbeat.plan(budget: budget)
      log.call("── heartbeat plan ── budget #{plan.budget} tokens (change cap #{plan.change_cap})")
      plan.lane_counts.sort.each do |lane, reasons|
        log.call("   #{lane}: #{reasons.sort.map { |r, n| "#{r}=#{n}" }.join('  ')}")
      end
      log.call("   total: #{plan.items.size} item(s), est #{plan.est_total} tokens")
      log.call("   #{plan.horizon_line}")
      plan.warnings.each { |w| log.call("   ⚠ #{w}") }
      next
    end

    begin
      row = Enliterator::Heartbeat.beat!(
        execute:       ENV["ENQUEUE"].present? ? :enqueue : :sync,
        budget:        budget,
        skip_consider: ENV["SKIP_CONSIDER"].present?,
        force:         ENV["FORCE"].present?
      )
      log.call("heartbeat ##{row.id} #{row.error ? 'ABORTED' : 'done'} — " \
               "planned #{row.planned_count}, executed #{row.executed.values.sum { |c| c.values.sum }}, " \
               "tokens #{row.tokens_spent['total'] || 'enqueued'}")
      row.warnings.each { |w| log.call("   ⚠ #{w}") }
    rescue Enliterator::Heartbeat::Overlap => e
      abort "[enliterator:heartbeat] REFUSED: #{e.message}"
    end
  end

  # The retrospective conversion (v0.17): shelf-read the whole collection in
  # one run — the initial condition inventory. The heartbeat's survey phase is
  # the ONGOING shelf-read; without this task, adopting condition would mean
  # months of half-surveyed limbo where the gate and the conservation report
  # are misleading. Probes are column reads; this is minutes, not days.
  #
  #   bin/rails enliterator:survey
  #   LIMIT=5000 bin/rails enliterator:survey   # bounded first pass
  desc "Shelf-read the collection to completion (initial condition inventory). LIMIT=n"
  task survey: :environment do
    logger = Enliterator.logger
    log = ->(msg) { logger ? logger.info("[enliterator:survey] #{msg}") : puts(msg) }
    unless Enliterator::Condition.probes_registered?
      abort "[enliterator:survey] no condition probes registered — add Enliterator::Condition.register(...) to the host initializer"
    end

    limit = ENV["LIMIT"].presence&.to_i
    total = { "surveyed" => 0, "untendable" => 0, "degraded" => 0 }
    loop do
      batch_size = [ 2_000, limit ? limit - total["surveyed"] : 2_000 ].min
      break if batch_size <= 0
      # fresh_only: this task reads the shelf ONCE and terminates — the
      # stalest fallback would feed endless re-surveys (the heartbeat's
      # time-boxed phase owns the rolling re-read).
      batch = Enliterator::Condition.survey_due(limit: batch_size, fresh_only: true)
      break if batch.empty?

      Enliterator::Condition.survey_batch!(batch).each do |v|
        total["surveyed"]   += 1
        total["untendable"] += 1 if v[:band] == :untendable
        total["degraded"]   += 1 if v[:band] == :degraded
      end
      log.call("surveyed #{total['surveyed']} — untendable #{total['untendable']}, degraded #{total['degraded']}")
      break if batch.size < batch_size
    end
    log.call("done — #{Enliterator::Condition.surveyed_count} record(s) on the condition register; " \
             "#{Enliterator::Condition.untendable_count} untendable")
  end

  # The quality-review on-ramp (v0.18): examine N claims by hand before the
  # ride-along ever runs unattended — every loop gets a hand-crank first.
  # Prints each verdict + rationale so the examiner's judgment is READ, not
  # assumed (are its 'unsupported' calls real silence, or artifacts?).
  #
  #   N=25 bin/rails enliterator:audit
  desc "Examine a stratified sample of claims against their sources (quality review). N=count"
  task audit: :environment do
    logger = Enliterator.logger
    log = ->(msg) { logger ? logger.info("[enliterator:audit] #{msg}") : puts(msg) }
    n = (ENV["N"] || 10).to_i

    sample = Enliterator::Audit.sample(n)
    abort "[enliterator:audit] no unaudited claims in the pool" if sample[:claims].empty?
    log.call("sampling #{sample[:claims].size} claim(s): #{sample[:allocation].map { |k, v| "#{k}=#{v}" }.join('  ')}")

    examiner = Enliterator::Audit::Examiner.new
    sample[:claims].each_with_index do |claim, i|
      outcome = examiner.examine!(claim)
      case outcome
      when Enliterator::Audit
        log.call("[#{i + 1}/#{sample[:claims].size}] #{outcome.verdict.upcase.ljust(13)} " \
                 "#{claim.visit&.facet}/#{claim.key} #{claim.tendable_type}/#{claim.tendable_id}" \
                 "#{outcome.source_truncated ? ' (source truncated)' : ''}")
        log.call("    claim: #{claim.value.is_a?(String) ? claim.value[0, 140] : claim.value.to_json[0, 140]}")
        log.call("    examiner: #{outcome.rationale[0, 200]}")
      when :unavailable
        abort "[enliterator:audit] examiner unavailable (Null adapter) — configure the gateway"
      else
        log.call("[#{i + 1}/#{sample[:claims].size}] skipped (#{outcome}) #{claim.tendable_type}/#{claim.tendable_id}")
      end
    end

    Enliterator::Audit.accuracy.each do |c|
      log.call("#{c[:facet]}/#{c[:tier]}: audited #{c[:audited]} — supported #{c[:supported]}, " \
               "unsupported #{c[:unsupported]}, contradicted #{c[:contradicted]}, unverifiable #{c[:unverifiable]}")
    end
  end

  # Run the considerer over the open vocabulary requests: refresh pressure, ask the
  # agent across the whole field, auto-apply the safe verdicts (maps + confident
  # rejects), hold approves for ratification. Wire this AFTER enliterator:tend in
  # the host scheduler so the vocabulary converges each cycle. (v0.15: the
  # heartbeat runs this pass itself each cycle — keep this task for hosts that
  # schedule governance separately, with SKIP_CONSIDER=1 on the heartbeat.)
  #
  #   bin/rails enliterator:consider
  #   CONTEXT=crs-reports bin/rails enliterator:consider   # one context's open field (v0.13)
  desc "Consider open vocabulary requests (auto-apply safe verdicts; hold approves). CONTEXT=key"
  task consider: :environment do
    logger = Enliterator.logger
    log = ->(msg) { logger ? logger.info("[enliterator:consider] #{msg}") : puts(msg) }
    ctx = ENV["CONTEXT"].present? ? Enliterator::Context.find_by_key!(ENV["CONTEXT"]) : nil
    s = Enliterator::Considerer.new(context: ctx).consider!
    log.call("considered #{s[:considered]}#{ctx ? " in #{ctx.key}" : ''} — auto-mapped #{s[:auto_mapped]}, " \
             "auto-rejected #{s[:auto_rejected]}, #{s[:approves_recommended]} approval(s) recommended, #{s[:held]} held")
  end

  # Tend a context's members along the context's OWN declared facets (v0.13,
  # rule 2: declaration location = tending scope — root facets tend at root via
  # enliterator:tend, not per child). Synchronous and staged like tend_theses:
  # skips members already tended on a facet in this context, so runs never overlap.
  #
  #   CONTEXT=executive-orders bin/rails enliterator:tend_context
  #   CONTEXT=crs-reports LIMIT=5 FACET=policy_analysis bin/rails enliterator:tend_context
  desc "Tend a context's members along its own facets. CONTEXT=key LIMIT=n FACET=name"
  task tend_context: :environment do
    logger = Enliterator.logger
    log = ->(msg) { logger ? logger.info("[enliterator:tend_context] #{msg}") : puts(msg) }

    ctx    = Enliterator::Context.find_by_key!(ENV.fetch("CONTEXT"))
    facets = ENV["FACET"].present? ? [ ENV["FACET"] ] : Enliterator.staffing.facets_declared_in(ctx.key)
    abort "context #{ctx.key} declares no facets of its own (inherits only) — pass FACET= to force one" if facets.empty?
    limit  = ENV["LIMIT"].presence&.to_i

    facets.each do |facet|
      # Members not yet tended on this facet IN this context (non-overlapping stages).
      done = Enliterator::Visit
               .where(context_id: ctx.id, facet: facet, status: "succeeded", applied: true)
               .distinct.pluck(:tendable_type, :tendable_id).to_set
      members = ctx.memberships.order(:created_at)
                  .reject { |m| done.include?([ m.member_type, m.member_id ]) }
      members = members.first(limit) if limit

      log.call("#{ctx.key} / #{facet}: tending #{members.size} member(s) (#{done.size} already done)")
      members.each_with_index do |m, i|
        record = m.member
        next log.call("  [#{i + 1}] #{m.member_type}/#{m.member_id} MISSING — skipped") if record.nil?

        v = record.tend!(facet: facet, context: ctx)
        log.call("  [#{i + 1}/#{members.size}] #{m.member_type}/#{m.member_id} tier=#{v.tier} conf=#{v.confidence} status=#{v.status}")
      rescue => e
        log.call("  [#{i + 1}/#{members.size}] #{m.member_type}/#{m.member_id} FAILED #{e.class}: #{e.message}")
      end
    end
  end
end
