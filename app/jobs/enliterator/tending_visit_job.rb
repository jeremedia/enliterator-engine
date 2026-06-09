module Enliterator
  # Tends one record along one facet. The record is passed as an ActiveJob
  # argument and serialized via GlobalID, so the host's queue backend (Sidekiq
  # for HSDL, anything ActiveJob-compatible elsewhere) carries only a reference.
  #
  #   Enliterator::TendingVisitJob.perform_later(record, "summary")
  #   Enliterator::TendingVisitJob.perform_later(record, "directive", context,
  #                                              heartbeat_id: hb.id, reason: "frontier")
  #
  # v0.15: optionally carries the tending context plus heartbeat provenance.
  # Old 2-arg jobs already serialized in a queue keep working (defaults).
  # heartbeat_id is a plain integer (not GlobalID) so a deleted ledger row can
  # never fail deserialization — the visit is simply stamped with nil + reason.
  class TendingVisitJob < ApplicationJob
    # Transient failures (LLM/network/embedder hiccups) get a few backoff retries.
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    # If the record was deleted between enqueue and run, there's nothing to tend.
    discard_on ActiveJob::DeserializationError

    def perform(tendable, facet, context = nil, heartbeat_id: nil, reason: nil)
      heartbeat = heartbeat_id && Enliterator::Heartbeat.find_by(id: heartbeat_id)
      tendable.tend!(facet: facet, context: context, heartbeat: heartbeat, reason: reason)
    end
  end
end
