# Enliterator scheduled tending walk.
#
# For every registered tendable model and every configured stream, enqueue a
# TendingVisitJob for up to `tend_batch_size` records whose newest succeeded
# visit is older than `stale_after` (or that have never succeeded). Hosts wire
# this to their scheduler (HSDL: sidekiq-cron; others: solid_queue recurring).
#
#   bin/rails enliterator:tend
#
namespace :enliterator do
  desc "Enqueue tending visits for stale/untended records (per model, per stream)"
  task tend: :environment do
    config  = Enliterator.configuration
    streams = Array(config.tending_streams)
    batch   = config.tend_batch_size
    cutoff  = Time.current - config.stale_after
    logger  = Enliterator.logger

    log = ->(msg) { logger ? logger.info("[enliterator:tend] #{msg}") : puts("[enliterator:tend] #{msg}") }

    total_enqueued = 0

    Enliterator.tendable_models.each do |model|
      type_name = model.name

      streams.each do |stream|
        stream = stream.to_s

        # Tendable ids that are FRESH for this stream: their newest succeeded
        # visit finished at or after the cutoff. Everything else (stale or never
        # succeeded) is a candidate. tendable_id is stored as a string, so cast
        # the host PK to text for the comparison (works for bigint and uuid PKs).
        fresh_ids =
          Enliterator::Visit
            .where(tendable_type: type_name, stream: stream, status: "succeeded")
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
          Enliterator::TendingVisitJob.perform_later(record, stream)
        end

        enqueued = candidates.size
        total_enqueued += enqueued

        note = capped ? " (cap #{batch} hit — more stale records remain for this model/stream)" : ""
        log.call("#{type_name} / #{stream}: enqueued #{enqueued}#{note}")
      end
    end

    log.call("done — enqueued #{total_enqueued} tending visit(s) across #{Enliterator.tendable_models.size} model(s) and #{streams.size} stream(s)")
  end
end
