require "enliterator/version"
require "enliterator/engine"

# Enliterator — confer literacy on data.
#
# Mount the engine, `include Enliterator::Tendable` on any host model, and that
# record gains embeddings, a provenance-tracked claim store, quality facets, and
# a tending loop where each visit reads the record's accumulated history plus its
# corpus neighbors and reconciles its understanding. Understanding compounds.
#
# Configure once (host initializer):
#
#   Enliterator.configure do |c|
#     c.llm_adapter      = Enliterator::Adapters::LLM::Bedrock.new(model_id: "...")
#     c.embedder_adapter = Enliterator::Adapters::Embedder::OpenAI.new
#     c.default_embedding_dimensions = 1536
#     c.tend_batch_size  = 50
#   end
module Enliterator
  # Raised when an adapter is invoked but the host has not configured/bundled it.
  class ConfigurationError < StandardError; end

  class Configuration
    # Adapters (see app/services/enliterator/adapters). When nil, the corresponding
    # Null adapter is used — safe for tests, inert in production (raises on real calls).
    attr_accessor :llm_adapter, :embedder_adapter

    # Vector width for the embeddings table / neighbor index.
    attr_accessor :default_embedding_dimensions

    # How many least-recently-tended records the scheduled walk enqueues per run.
    attr_accessor :tend_batch_size

    # Named tending lanes a record is visited along (each its own prompt/cadence).
    attr_accessor :tending_streams

    # Re-tend a record whose newest visit is older than this (confidence/staleness decay).
    attr_accessor :stale_after

    # ActiveJob queue used by TendingVisitJob.
    attr_accessor :queue_name

    attr_writer :logger

    def initialize
      @llm_adapter = nil
      @embedder_adapter = nil
      @default_embedding_dimensions = 1536
      @tend_batch_size = 50
      @tending_streams = [ :summary ]
      @stale_after = 90.days
      @queue_name = :enliterator
    end

    def logger
      @logger || (defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil)
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    # The active LLM adapter, or a Null adapter that no-ops in tests and raises in prod.
    def llm
      configuration.llm_adapter || Adapters::LLM::Null.new
    end

    # The active embedder adapter, or a Null adapter.
    def embedder
      configuration.embedder_adapter || Adapters::Embedder::Null.new
    end

    def logger
      configuration.logger
    end

    # Host models that have `include Enliterator::Tendable` register here so the
    # scheduled walk knows what to tend.
    def tendable_models
      @tendable_models ||= []
    end

    def register_tendable(model)
      tendable_models << model unless tendable_models.include?(model)
    end
  end
end
