require "enliterator/version"
require "enliterator/engine"

# Enliterator — confer literacy on data.
#
# Mount the engine, `include Enliterator::Tendable` on any host model, and that
# record gains embeddings, a provenance-tracked claim store, quality measures, and
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
    attr_accessor :tending_facets

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
    # policy (all facets → first available tier) is used at call time.
    attr_accessor :staffing

    # Confidence below which a visit escalates. Mirrors the Policy default; exposed
    # here so a host can tune escalation without rebuilding the whole policy block.
    attr_accessor :escalation_threshold

    # ---- v0.3 Governed Suggestion Loop -----------------------------------

    # A callable (default nil) invoked with each newly-created Enliterator::Suggestion
    # when the model proposes a claim key outside a facet's contract. The hook lets a
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

    # ---- v0.15 Heartbeat (event-driven tending) ---------------------------

    # The per-cycle token budget (Visit.tokens.total summed). Sync mode enforces
    # this on ACTUALS — the cycle cannot exceed its appropriation. Tier-blind:
    # a free on-prem token counts the same as a paid one (dollars stay derivable
    # from the ledger's by_tier + Spend's price_map).
    attr_accessor :heartbeat_budget_tokens

    # The fraction of the budget reserved for CHANGE-TRIGGERED re-tends
    # (source-change → neighborhood → vocabulary, in that order). Unused change
    # budget spills to the frontier; the stale sweep gets only what's left.
    attr_accessor :heartbeat_change_share

    # How many context-mates must have been tended since a record's last visit
    # in a lane before the neighborhood trigger fires (v0.14's measured signal).
    attr_accessor :heartbeat_neighbor_threshold

    # Optional host override for the source-change test: a callable
    # `(record, last_started_at) -> bool`. nil ⇒ the default comparison
    # `record.updated_at > last_started_at` — approximate (touch chains, host
    # backfills also move updated_at); hosts with a real content timestamp or
    # digest should point this at it.
    attr_accessor :heartbeat_source_changed

    # ---- v0.17 Condition (the collection shelf-reads itself) ---------------

    # Wall-clock budget (ms) for the per-cycle survey phase: probes are
    # column-reads, so the bound is time, not tokens.
    attr_accessor :heartbeat_survey_budget_ms

    # When the survey asserts the locked `source_status` claim: :untendable
    # (default — only records the engine cannot read get a catalog note) or
    # :all (degraded records too — the dead-link-with-surrogate note enters
    # literacy_state/Chat, at a prompt-token cost on every future visit).
    attr_accessor :condition_claim_scope

    # ---- v0.18 Audit (accuracy, measured) ----------------------------------

    # Claims examined per heartbeat cycle. DEFAULT 0 = OFF: setting it non-zero
    # IS the adoption act (quality-tier spend must never start on a gem
    # upgrade). Count-bounded; audit spend is outside the tending token budget.
    attr_accessor :heartbeat_audit_sample

    # Tier the examiner reasons with (nil ⇒ ladder top, else "quality").
    attr_accessor :audit_tier

    # Ceiling on the source text handed to the examiner. Generous by design:
    # the tend read the FULL text, and a snippet-bound examiner yields false
    # "unsupported" for deep-grounded claims. Truncation is stamped on the row.
    attr_accessor :audit_source_chars

    # ---- v0.21 The Atlas ---------------------------------------------------

    # Node ceiling for the atlas graph. Over it, the most-connected nodes are
    # kept and the meta says so (an honest cap, never a silent one).
    attr_accessor :atlas_node_cap

    # ---- v0.23 Bounded gateway calls ----------------------------------------

    # Per-request timeout (seconds) and retry count for the gateway + embedder
    # clients. The openai gem's defaults (600s × retries) let one wedged call
    # stall a heartbeat phase for tens of minutes with no sign of life; a
    # bounded call becomes a COUNTED failure instead of a hung cycle.
    attr_accessor :gateway_timeout, :gateway_max_retries

    # ---- v0.28 Agentic Reference Desk ------------------------------------

    # Gate for the agentic federation. nil/false ⇒ /enliterator/chat is the
    # byte-identical single-shot RAG. true ⇒ the controller drives Chat::Loop,
    # routing through the Chat::Agent registry.
    attr_accessor :chat_federation

    # v0.35 Stage C. nil/false ⇒ no follow-up directive is injected and no
    # :followups event is emitted (byte-identical to v0.34). true ⇒ the Loop asks
    # the model for an inline %%FOLLOWUPS%% block, parses it, emits :followups, and
    # logs the outcome. Nests under chat_federation (the Loop only runs when that is on).
    attr_accessor :chat_followups

    # v0.36: the engine-owned reference REGISTER (the desk's voice). nil/false ⇒
    # not injected (byte-identical to v0.35). true ⇒ the built-in
    # Enliterator::Chat::Register::DEFAULT (institution-formal LIS voice) is
    # prepended to every answering desk's system prompt. A String ⇒ that custom
    # register text instead. Nests under chat_federation (only the Loop applies it).
    attr_accessor :chat_register

    # v0.37: gates the /enliterator/desks persona-editing surface. nil/false ⇒
    # the controller 404s (and no nav link). A write surface that changes desk
    # behavior, so opt-in. The persona STORE resolution is always live (inert when
    # empty); this gates only the editing UI.
    attr_accessor :chat_persona_editing

    # v0.37: optional auth-agnostic editor-identity seam. nil ⇒ editors recorded as
    # nil (dev). A callable ->(request) { "identity" } lets a host behind auth record
    # who edited a persona without the engine imposing an auth model.
    attr_accessor :chat_editor

    # v0.39: gates chat retention. nil/false ⇒ no capture, replay/browse 404, no
    # nav link (byte-identical to v0.38, stateless desk). true ⇒ federation turns
    # persist (the dev/demo backend) and can be re-streamed.
    attr_accessor :chat_retention

    # ---- v0.30 Actionable error reporting --------------------------------

    # 3-state switch for surfacing ACTIONABLE error detail (exception
    # class/message, where, a remediation hint) to the chat frontend:
    #   nil   = auto (on in dev — see error_detail_auto)
    #   true  = force on
    #   false = force off
    # Read through error_detail?, never directly. The auto predicate is
    # host-overridable via error_detail_auto= (below) for a host that keeps its
    # error policy strictly env-free.
    attr_accessor :error_detail

    # Optional host override for the auto predicate (a callable returning truthy
    # when detail should show). nil ⇒ the default env guard (Rails.env.development?).
    attr_writer :error_detail_auto

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
      @tending_facets = [ :summary ]
      @stale_after = 90.days
      @queue_name = :enliterator
      @gateway_base_url = "https://llm.domt.app/v1"
      @gateway_api_key = nil
      @staffing = nil
      @escalation_threshold = 0.6
      @suggestion_sink = nil
      @chat_federation = nil
      @chat_followups = nil
      @chat_register = nil
      @chat_persona_editing = nil
      @chat_editor = nil
      @chat_retention = nil
      @error_detail = nil
      @allow_null_llm = false
      @conversation_tier = nil
      @considerer_tier = nil
      @considerer_autonomy = :auto_safe
      @considerer_min_confidence = 0.75
      @apply_approved_keys = true
      @heartbeat_budget_tokens = 200_000
      @heartbeat_change_share = 0.2
      @heartbeat_neighbor_threshold = 3
      @heartbeat_source_changed = nil
      @heartbeat_survey_budget_ms = 10_000
      @condition_claim_scope = :untendable
      @heartbeat_audit_sample = 0
      @audit_tier = nil
      @audit_source_chars = 24_000
      @atlas_node_cap = 1_500
      @gateway_timeout = 180
      @gateway_max_retries = 1
    end

    def logger
      @logger || (defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil)
    end

    # Whether to surface ACTIONABLE error detail (exception class/message, where, a
    # remediation hint) to the chat frontend. 3-state: nil = auto (on in dev), true =
    # force on, false = force off. The auto predicate is host-overridable via
    # error_detail_auto= so a strictly env-policy-free host can replace it.
    def error_detail?
      return !!@error_detail unless @error_detail.nil?
      !!error_detail_auto.call
    end

    def error_detail_auto
      @error_detail_auto || -> { defined?(Rails) && Rails.respond_to?(:env) && Rails.env.development? }
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
    # a safe default that routes every facet to a single tier so the engine runs
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

    # v0.25: is this class a legitimate tendable TYPE for the drill-down
    # surfaces (status#show, the catalog's type filter)? Registered host
    # models plus the engine's own Part — parts carry claims and deserve an
    # entry page, but they are deliberately NOT in the registry (no root
    # lanes, no corpus census).
    def tendable_type?(klass)
      return false if klass.nil?
      klass == Enliterator::Part || tendable_models.include?(klass)
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
    # facet to a single tier (the caller-supplied one, else the on-prem/free
    # "cheap" alias) so the engine still runs.
    def default_staffing_policy(default_tier)
      Staffing::Policy.default(default_tier || "cheap")
    end
  end
end
