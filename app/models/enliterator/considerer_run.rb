module Enliterator
  # The async considerer run ledger (v0.48). One row per consider! invocation
  # triggered from the Requests UI. Mirrors Heartbeat's pattern exactly:
  #   open!          — advisory lock → reap_orphans! → overlap check → create row
  #   execute_async! — named Thread under executor.wrap → execute! → stamp
  #   execute!       — run Considerer#consider! with a progress block → finalize
  #   pulse!(done, total) — liveness stamp from inside the progress block
  #   reap_orphans!  — stamp stale unfinished rows, called from open! and the UI
  #
  # The row IS the overlap lock: two concurrent "Consider" button clicks hold
  # a Postgres advisory lock while they check, so only one row ever opens.
  class ConsidererRun < ApplicationRecord
    OVERLAP_WINDOW = 6.hours
    REAP_AFTER     = 15.minutes
    STALL_AFTER    = 5.minutes

    # Raised when an unfinished run younger than the window exists — a running
    # or crashed consider run. The caller surfaces this to the user via flash.
    class Overlap < StandardError; end

    scope :unfinished, -> { where(finished_at: nil) }

    belongs_to :context, class_name: "Enliterator::Context", optional: true

    # Open a run: take the advisory lock, reap orphans, check for overlap,
    # create the row. Returns the new row.
    def self.open!(context: nil)
      transaction do
        connection.execute("SELECT pg_advisory_xact_lock(hashtext('enliterator_considerer'))")

        # Bury the dead first — an orphaned row must not block a new run.
        reap_orphans!

        open_row = unfinished.where("started_at > ?", OVERLAP_WINDOW.ago).order(:started_at).last
        if open_row
          raise Overlap, "considerer run ##{open_row.id} is still open " \
                         "(started #{open_row.started_at.iso8601}) — " \
                         "wait for it to finish, or check if it crashed."
        end

        create!(
          context_id: context&.id,
          status:     "running",
          started_at: Time.current,
          batch_size: Enliterator.configuration.considerer_batch_size
        )
      end
    end

    # Execute the run in a background thread and return the thread.
    # Deliberately not ActiveJob: a dead worker would be a silent no-op.
    # The outer rescue covers failures OUTSIDE execute!'s own rescue (e.g. a
    # crash of finalize itself) — a best-effort stamp so the row never just
    # stops moving with no explanation.
    def execute_async!
      thread = Thread.new do
        Rails.application.executor.wrap do
          execute!
        end
      rescue => e
        Enliterator.logger&.error("[enliterator:considerer] async run ##{id} died: #{e.class}: #{e.message}")
        begin
          update_columns(finished_at: Time.current, status: "error",
                         error: "#{e.class}: #{e.message}") if reload.finished_at.nil?
        rescue StandardError
          nil
        end
      end
      thread.name = "enliterator-considerer-#{id}"
      thread
    end

    # Drive the Considerer and finalize the row. Called from execute_async! in
    # the background thread, or directly in tests. The progress block threads
    # through to Considerer#consider! so each batch stamps the row.
    def execute!
      ctx     = context_id && Enliterator::Context.find_by(id: context_id)
      summary = Enliterator::Considerer.new(context: ctx).consider! { |done, total|
        pulse!(done, total)
      }
      update!(summary: summary, status: "finished", finished_at: Time.current, phase: "done")
    rescue => e
      update_columns(finished_at: Time.current, status: "error",
                     error: "#{e.class}: #{e.message}")
      raise
    end

    # Liveness stamp — called from the progress block inside execute! after each
    # batch. update_columns skips callbacks and updated_at churn; one cheap UPDATE.
    def pulse!(done, total)
      update_columns(pulse_at: Time.current, done_count: done, planned_count: total,
                     phase: "considering")
    end

    # Stamp every orphaned row — unfinished, with no sign of life for REAP_AFTER.
    # Called from open! (a dead row must not block the next run) and the monitor
    # (the UI heals on view via index + pulse endpoint).
    def self.reap_orphans!
      unfinished.where("COALESCE(pulse_at, updated_at, started_at) < ?", REAP_AFTER.ago)
                .order(:id).map(&:reap!)
    end

    # Unfinished with no sign of life past the reap threshold. The pulse endpoint
    # uses this so a watched monitor self-heals.
    def orphaned?
      !finished? && (pulse_at || updated_at || started_at) < REAP_AFTER.ago
    end

    # The honest ending for a run whose process died.
    def reap!
      last_life = pulse_at || updated_at || started_at
      update!(
        finished_at: last_life,
        status:      "reaped",
        phase:       nil,
        error:       "considerer process died (last sign of life #{last_life.iso8601})"
      )
      self
    end

    def finished?
      finished_at.present?
    end
  end
end
