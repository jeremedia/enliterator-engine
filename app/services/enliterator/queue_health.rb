# frozen_string_literal: true

module Enliterator
  # v0.72.4 — LOUD ENQUEUE.
  #
  # The rule-3 violation this closes was live: 32 TendingVisitJobs sat in a
  # queue with no consumer, silently, indefinitely (dev had no Sidekiq worker;
  # the sync-mode beat never noticed). The v0.23 drain-deficit check fires
  # after the fact; this one fires at the moment of enqueue — when someone can
  # still act.
  #
  # Adapter-FIRST, gem-presence second: `defined?(Sidekiq::ProcessSet)` is true
  # for any host that merely BUNDLES sidekiq while running solid_queue/async
  # (false warnings), and a non-Sidekiq adapter with real consumers would read
  # "no consumer". Any adapter other than sidekiq → nil (unknown, silent) —
  # this is a Sidekiq liveness probe, not a queue oracle.
  #
  # A liveness probe must never break an enqueue: everything rescues to nil.
  module QueueHealth
    LOG_INTERVAL = 60 # seconds — rate-limits the LOG line, never the return

    class << self
      # true / false / nil (nil = cannot know: non-sidekiq adapter, no gem,
      # or the probe failed — silence, not a warning).
      def consumer_listening?
        return nil unless Enliterator::TendingVisitJob.queue_adapter_name == "sidekiq"
        return nil unless defined?(Sidekiq::ProcessSet)

        # The engine's job classes use block-form `queue_as { … }`, so the
        # CLASS attribute is a Proc — its to_s matches no Sidekiq queue ever.
        # The configuration value is the truth the block resolves to.
        queue = Enliterator.configuration.queue_name.to_s
        Sidekiq::ProcessSet.new.any? { |p| Array(p["queues"]).map(&:to_s).include?(queue) }
      rescue StandardError
        nil
      end

      # ALWAYS returns the warning string when no consumer is listening (nil
      # otherwise) — callers that keep a ledger (heartbeat run_warnings) must
      # get it every cycle, or the ledger under-reports while the queue still
      # has no consumer. Only the LOG emission is rate-limited (the per-job
      # flood exists at the rake tend loop, not in the ledger).
      def warn_if_unconsumed(context: nil)
        return nil unless consumer_listening? == false

        queue = Enliterator.configuration.queue_name.to_s
        msg = "no Sidekiq worker is listening on queue '#{queue}' — enqueued work will sit " \
              "unprocessed until one starts#{context ? " (#{context})" : ''}"
        now = monotonic_now
        if @last_logged_at.nil? || now - @last_logged_at >= LOG_INTERVAL
          @last_logged_at = now
          Enliterator.configuration.logger&.warn("[enliterator] event=queue_unconsumed #{msg}")
        end
        msg
      rescue StandardError
        nil
      end

      # Test seam.
      def reset!
        @last_logged_at = nil
      end

      private

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
