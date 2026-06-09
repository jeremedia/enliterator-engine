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

    # ---- v0.2 Staffing & Routing -----------------------------------------

    # LiteLLM gateway (OpenAI-compatible) the tier adapters target. The engine
    # names intent (a tier alias) and tags the call; it NEVER names a provider.
    attr_accessor :gateway_base_url

    # LiteLLM project key. From ENV — never committed. nil leaves Gateway tiers
    # unconfigured, in which case Enliterator.llm(tier:) falls back to the v0.1 path.
    attr_accessor :gateway_api_key

    # An Enliterator::Staffing::Policy (the org chart). nil → a safe default
    # policy (all streams → first available tier) is used at call time.
    attr_accessor :staffing

    # Confidence below which a visit escalates. Mirrors the Policy default; exposed
    # here so a host can tune escalation without rebuilding the whole policy block.
    attr_accessor :escalation_threshold

    # ---- v0.3 Governed Suggestion Loop -----------------------------------

    # A callable (default nil) invoked with each newly-created Enliterator::Suggestion
    # when the model proposes a claim key outside a stream's contract. The hook lets a
    # host forward proposals to a shared vocabulary tracker (KN, a review queue, etc.).
    # nil ⇒ suggestions are persisted locally only (no forwarding) — the default path.
    attr_accessor :suggestion_sink

    # ---- v0.6 Conversation -----------------------------------------------

    # The capability tier (LiteLLM alias) the conversation UI uses for free-form
    # answers. nil ⇒ resolve at call time to the staffing ladder's top tier, else
    # "quality" — conversation wants capability. A host can pin it explicitly.
    attr_accessor :conversation_tier

    # ---- v0.8 Considerer (the vocabulary tends itself) -------------------

    # Tier the considerer agent reasons with (nil ⇒ ladder top, else "quality").
    attr_accessor :considerer_tier
    # Autonomy: :auto_safe (auto-apply maps/rejects, hold approves for ratification)
    # or :recommend_only (hold everything as a recommendation).
    attr_accessor :considerer_autonomy
    # Min confidence for the considerer to AUTO-APPLY a map/reject (else held).
    attr_accessor :considerer_min_confidence

    # ---- v0.9 Convergence -------------------------------------------------

    # When true (default), an APPROVED proposed key joins the effective contract
    # (Enliterator::Vocabulary.for) the model sees — so it's emitted as a claim and
    # stops being re-proposed. Set false to keep the contract code-only (approvals
    # stay advisory, surfaced as a diff to codify by hand).
    attr_accessor :apply_approved_keys

    # ---- v0.5 Silent-failure hardening -----------------------------------

    # When false (the default), a real tend that resolves to the inert Null LLM
    # adapter on the STAFFING path RAISES instead of writing a phantom "succeeded"
    # Visit with zero claims. This is the difference between a misconfiguration
    # failing LOUDLY and silently no-op-succeeding (the engine's own docstring
    # already promises Null "raises on real calls"). Tests that legitimately run
    # the Null adapter set this true (the engine's spec suite opts in suite-wide).
    attr_accessor :allow_null_llm

    attr_writer :logger

    def initialize
      @llm_adapter = nil
      @embedder_adapter = nil
      @default_embedding_dimensions = 1536
      @tend_batch_size = 50
      @tending_streams = [ :summary ]
      @stale_after = 90.days
      @queue_name = :enliterator
      @gateway_base_url = "https://llm.domt.app/v1"
      @gateway_api_key = nil
      @staffing = nil
      @escalation_threshold = 0.6
      @suggestion_sink = nil
      @allow_null_llm = false
      @conversation_tier = nil
      @considerer_tier = nil
      @considerer_autonomy = :auto_safe
      @considerer_min_confidence = 0.75
      @apply_approved_keys = true
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
      @gateway_adapters = nil
    end

    # The active LLM adapter.
    #
    # v0.1 path (no tier requested): the configured llm_adapter, or a Null adapter
    # that no-ops in tests and raises in prod. PRESERVED exactly — existing callers
    # and specs that inject `llm:` or rely on Enliterator.llm see no change.
    #
    # v0.2 path (tier requested AND gateway configured): build/memoize an
    # Adapters::LLM::Gateway for that tier, pointed at the LiteLLM gateway. The
    # Visitor requests the tier the staffing policy returns. If the gateway is not
    # configured (no api_key), fall back to the v0.1 adapter so the engine still
    # runs and existing specs stay green.
    def llm(tier: nil)
      return configuration.llm_adapter || Adapters::LLM::Null.new if tier.nil?

      if gateway_configured?
        gateway_adapters[tier.to_s] ||= Adapters::LLM::Gateway.new(
          tier:     tier.to_s,
          base_url: configuration.gateway_base_url,
          api_key:  configuration.gateway_api_key
        )
      else
        configuration.llm_adapter || Adapters::LLM::Null.new
      end
    end

    # The active staffing policy (the org chart). The host's configured policy, or
    # a safe default that routes every stream to a single tier so the engine runs
    # even when no staffing is configured.
    def staffing(default_tier: nil)
      configuration.staffing || default_staffing_policy(default_tier)
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

    private

    # True when the LiteLLM gateway has enough config to build tier adapters.
    def gateway_configured?
      configuration.gateway_api_key.present? &&
        configuration.gateway_base_url.present?
    end

    # Per-tier memoized Gateway adapters. Cleared by reset_configuration!.
    def gateway_adapters
      @gateway_adapters ||= {}
    end

    # The default org chart used when the host configures no staffing. Routes every
    # stream to a single tier (the caller-supplied one, else the on-prem/free
    # "cheap" alias) so the engine still runs.
    def default_staffing_policy(default_tier)
      Staffing::Policy.default(default_tier || "cheap")
    end
  end
end
