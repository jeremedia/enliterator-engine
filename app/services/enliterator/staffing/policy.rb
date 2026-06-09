module Enliterator
  module Staffing
    # The org chart for enliteration.
    #
    # Enliteration is the allocation of cognitive capacity to records — deciding
    # how much mind to bring to a record in a given state IS the curatorial act.
    # A tending **facet is a ROLE**; a LiteLLM **alias is a capability TIER**;
    # this policy is the **org chart** that maps roles to tiers, defines the
    # escalation ladder, and enforces the constraints (on-prem, context window,
    # verification floor) that keep a cheap pass from poisoning the well.
    #
    # Built with a block DSL:
    #
    #   Enliterator::Staffing::Policy.new do
    #     assign :summary, tier: "cheap"
    #     embedding_tier "embed"
    #     ladder ["cheap", "quality"]
    #     escalation_threshold 0.6
    #     max_promotions 1
    #     verify_floor "quality"
    #     on_prem_tiers ["cheap"]
    #     context_cap "instant", 4096
    #   end
    #
    # API consumed by the Visitor:
    #   tier_for(facet)              -> the alias for a role
    #   ladder_from(tier)            -> tiers at/after `tier` in ladder order
    #   escalate?(visit)             -> low confidence OR model flagged escalate
    #   may_verify?(tier)            -> tier at/above verify_floor
    #   allowed_tiers(tendable, facet) -> ladder clamped by constraints
    #   validate!(available_aliases) -> raise on unknown alias (fail fast at boot)
    class Policy
      DEFAULT_ESCALATION_THRESHOLD = 0.6
      DEFAULT_MAX_PROMOTIONS = 1

      attr_reader :assignments, :ladder_tiers, :embedding_alias, :on_prem_tier_list,
                  :context_caps, :term_lists, :required_term_map

      def initialize(&block)
        @assignments       = {}
        @ladder_tiers      = []
        @embedding_alias   = nil
        @escalation_threshold = DEFAULT_ESCALATION_THRESHOLD
        @escalate_when     = nil
        @max_promotions    = DEFAULT_MAX_PROMOTIONS
        @verify_floor      = nil
        @on_prem_tier_list = []
        @context_caps      = {}
        @term_lists     = {}
        @required_term_map  = {}

        instance_eval(&block) if block
      end

      # ---- DSL -------------------------------------------------------------

      # Map a facet (role) to a capability tier (alias).
      def assign(facet, tier:)
        @assignments[facet.to_s] = tier.to_s
        self
      end

      # Map a facet (role) to a tier AND bind its output contract: the controlled
      # vocabulary of claim keys the model may assert on this facet. `keys` is a
      # `{ key_sym => "description" }` hash. Sets the tier exactly as #assign does,
      # then records the contract so the Visitor can constrain the prompt/schema and
      # route off-list observations into `suggestions`. Facets declared with #assign
      # (no contract) remain unconstrained — open keys, back-compat.
      # +required+ (v0.5, optional): a subset of `keys` the model MUST assert a
      # non-blank claim for. When a required key comes back absent or empty, the
      # Visitor forces escalation regardless of confidence, and the top tier refuses
      # to mint `verified` while a required key is unmet. nil/omitted ⇒ no required
      # keys ⇒ byte-identical to v0.3/v0.4.
      def facet(name, tier:, terms:, required: nil)
        assign(name, tier: tier)
        @term_lists[name.to_s] =
          terms.each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
        req = Array(required).map(&:to_s).reject(&:empty?)
        @required_term_map[name.to_s] = req unless req.empty?
        self
      end

      # The alias used for embedding calls (the embed role).
      def embedding_tier(tier = :__read__)
        return @embedding_alias if tier == :__read__
        @embedding_alias = tier&.to_s
        self
      end

      # Ordered tiers for escalation, junior -> senior, e.g. ["cheap", "quality"].
      def ladder(tiers = :__read__)
        return @ladder_tiers if tiers == :__read__
        @ladder_tiers = Array(tiers).map(&:to_s)
        self
      end

      # Confidence below which a visit escalates (default 0.6).
      def escalation_threshold(value = :__read__)
        return @escalation_threshold if value == :__read__
        @escalation_threshold = value.to_f
        self
      end

      # Override the escalation predicate entirely with a callable (visit) -> Bool.
      # When set, it composes with the model's recorded escalate flag in #escalate?.
      def escalate_when(callable = :__read__, &block)
        return @escalate_when if callable == :__read__ && block.nil?
        @escalate_when = block || callable
        self
      end

      # Bound the climb: how many promotions a single tending may make.
      def max_promotions(value = :__read__)
        return @max_promotions if value == :__read__
        @max_promotions = value.to_i
        self
      end

      # Minimum tier permitted to mint `verified` claims. Below the floor, claims
      # stay `draft` regardless of model assertion. Defaults to the top configured
      # tier (so a single-tier policy can verify).
      def verify_floor(tier = :__read__)
        return effective_verify_floor if tier == :__read__
        @verify_floor = tier&.to_s
        self
      end

      # Tiers that run on-prem (never routed off-prem, even on escalation).
      def on_prem_tiers(tiers = :__read__)
        return @on_prem_tier_list if tiers == :__read__
        @on_prem_tier_list = Array(tiers).map(&:to_s)
        self
      end

      # Set a context-window cap for a tier (inputs over it must escalate/chunk).
      def context_cap(tier, tokens)
        @context_caps[tier.to_s] = tokens.to_i
        self
      end

      # ---- Query API -------------------------------------------------------

      # The capability tier assigned to a facet. Falls back to the ladder head
      # (or the embedding alias as a last resort) so an unmapped facet still runs.
      def tier_for(facet)
        @assignments.fetch(facet.to_s) { @ladder_tiers.first || @embedding_alias }
      end

      # The output contract for a facet: a `{ key => description }` hash of the
      # claim keys the model may assert, or nil when the facet is unconstrained
      # (declared via #assign or not at all). nil ⇒ open keys (v0.2 behavior).
      def terms_for(facet)
        @term_lists[facet.to_s]
      end

      # The allowed claim keys for a facet as a `[String]`, or nil when the facet
      # is unconstrained. nil (not []) signals "no contract" so callers can branch
      # on presence without confusing it with an empty allow-list.
      def allowed_terms(facet)
        contract = @term_lists[facet.to_s]
        return nil if contract.nil?
        contract.keys
      end

      # The required claim keys for a facet as a `[String]`, or nil when the facet
      # declares none. nil (not []) signals "no required keys" so callers branch on
      # presence. Always a subset of allowed_terms(facet).
      def required_terms(facet)
        @required_term_map[facet.to_s]
      end

      # Tiers at/after `tier` in ladder order (the remaining climb). If `tier`
      # is not on the ladder, returns just [tier] (nowhere to climb).
      def ladder_from(tier)
        tier = tier.to_s
        idx = @ladder_tiers.index(tier)
        return [ tier ] if idx.nil?
        @ladder_tiers[idx..] || [ tier ]
      end

      # Should this visit escalate? True when confidence is below threshold OR the
      # model's recorded output asked to escalate. A custom escalate_when callable,
      # if set, replaces the confidence test but still composes with the flag.
      def escalate?(visit)
        return false if visit.nil?
        confidence_trips =
          if @escalate_when
            !!@escalate_when.call(visit)
          else
            visit.confidence.to_f < @escalation_threshold
          end
        confidence_trips || visit_escalate_flag?(visit)
      end

      # Is `tier` permitted to mint verified claims? (at/above the verify floor)
      def may_verify?(tier)
        floor = effective_verify_floor
        return true if floor.nil?
        tier = tier.to_s
        floor_idx = @ladder_tiers.index(floor)
        tier_idx  = @ladder_tiers.index(tier)
        # If either tier is off-ladder, fall back to exact-match permission.
        return tier == floor if floor_idx.nil? || tier_idx.nil?
        tier_idx >= floor_idx
      end

      # The escalation ladder a record/facet may actually traverse, after applying
      # constraints: on-prem-only records are clamped to the on-prem tiers (order
      # preserved). Always returns at least the assigned tier when allowed.
      def allowed_tiers(tendable, facet)
        base = ladder_for_stream(facet)

        if on_prem_only?(tendable)
          allowed = base & @on_prem_tier_list
          return allowed unless allowed.empty?
          # Record demands on-prem but none of its ladder is on-prem: restrict to
          # the intersection of the whole on-prem set with the ladder; if still
          # empty, return [] (nothing may legally run rather than route off-prem).
          return @ladder_tiers & @on_prem_tier_list
        end

        base
      end

      # Largest input (in tokens) a tier may receive, or nil if uncapped.
      def context_cap_for(tier)
        @context_caps[tier.to_s]
      end

      # Fail fast at boot: every tier this policy names must exist in the gateway's
      # advertised aliases (from GET /v1/models). Raises ConfigurationError listing
      # the unknown tiers.
      def validate!(available_aliases)
        available = Array(available_aliases).map(&:to_s).to_set
        named = referenced_tiers
        unknown = named.reject { |t| available.include?(t) }
        unless unknown.empty?
          raise Enliterator::ConfigurationError,
                "Staffing policy references unknown LiteLLM aliases: " \
                "#{unknown.sort.join(', ')}. Available: #{available.to_a.sort.join(', ')}."
        end
        self
      end

      # Every tier this policy names (assignments, ladder, embedding, on-prem,
      # verify floor, context caps) — deduped, for validation and introspection.
      def referenced_tiers
        tiers = []
        tiers.concat(@assignments.values)
        tiers.concat(@ladder_tiers)
        tiers << @embedding_alias if @embedding_alias
        tiers.concat(@on_prem_tier_list)
        tiers << effective_verify_floor if effective_verify_floor
        tiers.concat(@context_caps.keys)
        tiers.compact.uniq
      end

      # A safe default policy: all facets route to the single available alias,
      # the ladder is just that tier, and that tier may verify. Lets the engine
      # run when the host configures no staffing at all.
      def self.default(default_tier = "cheap")
        tier = default_tier.to_s
        new do
          ladder [ tier ]
          embedding_tier tier
          verify_floor tier
        end
      end

      private

      # The ladder for a facet: starts at the facet's assigned tier and includes
      # everything at/after it. If the assigned tier is off-ladder, the visitor
      # still gets a usable single-element climb.
      def ladder_for_stream(facet)
        ladder_from(tier_for(facet))
      end

      # Defaults to the top configured tier (last on the ladder) when unset, so a
      # single-tier policy can mint verified claims.
      def effective_verify_floor
        @verify_floor || @ladder_tiers.last
      end

      def on_prem_only?(tendable)
        tendable.respond_to?(:enliterator_on_prem_only?) &&
          !!tendable.enliterator_on_prem_only?
      end

      # The model may flag a need to escalate in its structured output. The Visitor
      # records the parsed payload on the Visit; read the flag defensively from the
      # common locations without assuming a specific column.
      def visit_escalate_flag?(visit)
        if visit.respond_to?(:escalate) && !visit.respond_to?(:escalations)
          # A literal #escalate attribute (only if it isn't the association reader).
          return true if truthy?(visit.escalate)
        end
        payload = visit.respond_to?(:raw_response) ? visit.raw_response : nil
        parsed  = visit.respond_to?(:parsed) ? visit.parsed : nil
        [ payload, parsed ].compact.any? { |h| flag_in?(h) }
      end

      def flag_in?(hash)
        return false unless hash.respond_to?(:[])
        truthy?(hash["escalate"]) || truthy?(hash[:escalate]) ||
          truthy?(hash["needs_review"]) || truthy?(hash[:needs_review])
      end

      def truthy?(value)
        value == true || value == "true" || value == 1 || value == "1"
      end
    end
  end
end
