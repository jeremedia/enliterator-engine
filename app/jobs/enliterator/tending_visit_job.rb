module Enliterator
  # Tends one record along one facet. The record is passed as an ActiveJob
  # argument and serialized via GlobalID, so the host's queue backend (Sidekiq
  # for HSDL, anything ActiveJob-compatible elsewhere) carries only a reference.
  #
  #   Enliterator::TendingVisitJob.perform_later(record, "summary")
  #
  class TendingVisitJob < ApplicationJob
    # Transient failures (LLM/network/embedder hiccups) get a few backoff retries.
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    # If the record was deleted between enqueue and run, there's nothing to tend.
    discard_on ActiveJob::DeserializationError

    def perform(tendable, facet)
      tendable.tend!(facet: facet)
    end
  end
end
