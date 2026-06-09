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

  # Run the considerer over the open vocabulary requests: refresh pressure, ask the
  # agent across the whole field, auto-apply the safe verdicts (maps + confident
  # rejects), hold approves for ratification. Wire this AFTER enliterator:tend in
  # the host scheduler so the vocabulary converges each cycle.
  #
  #   bin/rails enliterator:consider
  desc "Consider open vocabulary requests (auto-apply safe verdicts; hold approves)."
  task consider: :environment do
    logger = Enliterator.logger
    log = ->(msg) { logger ? logger.info("[enliterator:consider] #{msg}") : puts(msg) }
    s = Enliterator::Considerer.new.consider!
    log.call("considered #{s[:considered]} — auto-mapped #{s[:auto_mapped]}, " \
             "auto-rejected #{s[:auto_rejected]}, #{s[:approves_recommended]} approval(s) recommended, #{s[:held]} held")
  end
end
