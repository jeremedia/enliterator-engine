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

namespace :enliterator do
  # v0.21: export the atlas as ONE self-contained HTML file — open it in any
  # browser, no server, no dependencies. The shareable artifact.
  #
  #   bin/rails enliterator:atlas                          # tmp/enliterator-atlas.html
  #   FILE=tmp/hsdl-atlas.html bin/rails enliterator:atlas
  #   CONTEXT=election-security bin/rails enliterator:atlas  # one context's neighborhood
  #   TITLE="HSDL — the federation" bin/rails enliterator:atlas
  desc "Export the atlas as a self-contained HTML file. FILE= CONTEXT= TITLE="
  task atlas: :environment do
    context = ENV["CONTEXT"].present? ? Enliterator::Context.find_by_key!(ENV["CONTEXT"]) : nil
    data    = Enliterator::Atlas.assemble(context: context)   # fresh — an export is a snapshot
    title   = ENV["TITLE"].presence ||
              [ Rails.application.class.module_parent_name,
                context ? context.name : "the whole collection" ].join(" — ")

    html = Enliterator::AtlasController.render(
      template: "enliterator/atlas/export", layout: false,
      assigns: { atlas: data, title: title }
    )

    path = ENV["FILE"].presence || "tmp/enliterator-atlas.html"
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, html)
    puts "atlas → #{path} (#{data[:meta][:records]} record(s), #{data[:meta][:entities]} entit(ies), " \
         "#{data[:meta][:edge_count]} connection(s), #{(File.size(path) / 1024.0).round} KB)"
  end
end

namespace :enliterator do
  # v0.22: portability — move the enliteration between deployments instead of
  # re-buying the inference. Export everything learned (claims + provenance,
  # vocabulary, audits, embeddings; the condition register stays home by
  # design) into ONE archive; import it on a fresh deployment.
  #
  #   bin/rails enliterator:export FILE=tmp/enliteration.tar
  #   MEASURES=1 bin/rails enliterator:export        # include the condition register
  #   bin/rails enliterator:import FILE=tmp/enliteration.tar
  #   FORCE=1 bin/rails enliterator:import ...       # truncate + replace a non-empty target
  desc "Export the enliteration to one archive. FILE= MEASURES=1"
  task export: :environment do
    path = ENV["FILE"].presence || "tmp/enliteration.tar"
    FileUtils.mkdir_p(File.dirname(path))
    manifest = Enliterator::Portability.export(path, measures: ENV["MEASURES"].present?)
    rows = manifest["tables"].values.sum { |t| t["rows"] }
    puts "enliteration → #{path} (#{manifest['tables'].size} tables, #{rows} rows, " \
         "#{(File.size(path) / 1024.0 / 1024).round(1)} MB)"
  end

  desc "Import an enliteration archive. FILE= FORCE=1"
  task import: :environment do
    path = ENV["FILE"].presence || "tmp/enliteration.tar"
    abort "no archive at #{path} (FILE=...)" unless File.exist?(path)
    manifest = Enliterator::Portability.import(path, force: ENV["FORCE"].present?)
    puts "imported #{manifest['tables'].size} tables from #{manifest['host']} " \
         "(exported #{manifest['generated_at']})"
    unless manifest["tables"].key?("enliterator_measures")
      puts "condition register not imported (by design) — run: bin/rails enliterator:survey"
    end
  end
end

namespace :enliterator do
  # v0.27: the Brief — "how did last night's tending go?" without re-deriving
  # the query every morning. A time-windowed digest: heartbeat cycles, visits
  # by facet/tier/reason, failures WITH their errors, deep-read sessions,
  # governance motion. Pure read. (Per-facet depth lives in enliterator:status.)
  #
  #   bin/rails enliterator:brief             # last 12 hours
  #   HOURS=36 bin/rails enliterator:brief
  desc "Activity digest for the last HOURS (default 12): cycles, visits, failures, readings, governance"
  task brief: :environment do
    hours = (ENV["HOURS"].presence || 12).to_f
    b = Enliterator::Brief.report(since: hours.hours)
    fmt_n = ->(n) { ActiveSupport::NumberHelper.number_to_delimited(n) }
    # App-zone labels, the v0.23 convention — the system clock can be a different
    # zone than the collection speaks (launchd taught us that the hard way).
    at    = ->(t) { t ? t.in_time_zone.strftime("%m-%d %H:%M") : "—" }

    puts "── enliterator brief ── last #{b[:window][:hours]}h (since #{at.call(b[:window][:since])})"
    puts b[:headline]

    if b[:heartbeats].any?
      puts "\nheartbeats:"
      b[:heartbeats].each do |hb|
        line = "  #{at.call(hb[:at])}→#{hb[:finished_at] ? hb[:finished_at].in_time_zone.strftime('%H:%M') : 'RUNNING'}" \
               "  #{hb[:mode]}  planned #{hb[:planned]}" \
               "  executed #{hb[:executed].sort.map { |k, v| "#{k}=#{v}" }.join(' ')}" \
               "  tokens #{fmt_n.call(hb[:tokens])}"
        line += "  ⚠ ABORTED: #{hb[:error][0, 120]}" if hb[:error]
        puts line
        Array(hb[:warnings]).each { |w| puts "      ⚠ #{w}" }
      end
    end

    v = b[:visits]
    if v[:total].positive?
      puts "\nvisits: #{v[:total]} · #{fmt_n.call(v[:tokens])} tokens"
      puts "  by facet:  " + v[:by_facet].sort.map { |f, st| "#{f} #{st.map { |k, n| "#{n} #{k}" }.join(', ')}" }.join("  ·  ")
      puts "  by tier:   " + v[:by_tier].map { |k, n| "#{k}=#{n}" }.join("  ")
      puts "  by reason: " + v[:by_reason].map { |k, n| "#{k}=#{n}" }.join("  ")
    end

    f = b[:failures]
    if f[:count].positive?
      puts "\nfailures: #{f[:count]}#{f[:truncated] ? " (showing #{f[:sample].size})" : ''}"
      f[:sample].each { |x| puts "  #{at.call(x[:at])}  #{x[:facet]}/#{x[:tier]}  #{x[:record]} — #{x[:error] || '(no error recorded)'}" }
    end

    r = b[:readings]
    if r[:parts_read].positive? || r[:parts_failed].positive? || r[:syntheses].positive?
      puts "\ndeep reads: #{r[:records]} record(s) · #{r[:parts_read]} parts read" \
           "#{" · #{r[:parts_failed]} failed" if r[:parts_failed].positive?}" \
           " · #{r[:syntheses]} syntheses · #{fmt_n.call(r[:tokens])} tokens"
    end

    g = b[:governance]
    moved = g.values.sum { |h| h.values.sum { |x| x.is_a?(Hash) ? x.values.sum : x } }
    if moved.positive?
      puts "\ngovernance:"
      puts "  suggestions: #{g[:suggestions].map { |k, n| "#{k}=#{n}" }.join('  ')}" if g[:suggestions].any?
      puts "  term motion: #{g[:term_motion].map { |k, n| "#{k}=#{n}" }.join('  ')}" if g[:term_motion].any?
      g[:audits].each { |src, verdicts| puts "  audits (#{src}): #{verdicts.map { |k, n| "#{k}=#{n}" }.join('  ')}" }
    end

    puts "\nembeddings written: #{b[:embeddings][:written]}" if b[:embeddings][:written].positive?
  end
end
