# frozen_string_literal: true

module Enliterator
  module Chat
    module_function

    # The registry. Process-level; reset in specs. config.chat_federation gates
    # whether the controller uses it at all (back-compat: off → byte-identical
    # single-shot RAG; on → controller drives Chat::Loop).
    def registry = (@registry ||= {})
    def reset!   = (@registry = {})
    def agents   = registry.values
    def frontdesk = registry.values.find { |a| a.grounding.nil? }
    def for_context(key) = registry.values.find { |a| a.grounding == key.to_s } || frontdesk

    # Register an agent. Validates the tier resolves to a converse_with_tools-capable
    # adapter NOW (fail-fast at registration, never mid-stream).
    def register(name:, grounding:, system_prompt:, tools:, tier:, routes_to: [])
      adapter = Enliterator.llm(tier: tier)
      unless adapter.respond_to?(:converse_with_tools)
        raise Enliterator::ConfigurationError,
              "Chat agent #{name.inspect} tier #{tier.inspect} resolves to #{adapter.class} " \
              "which does not implement converse_with_tools (require the gateway; check the alias is advertised)"
      end

      # Re-registration is a silent overwrite by design (dev reloads clear the
      # module ivar first, so this only fires on a genuine in-process double-
      # registration). Warn so config drift is visible; never raise — a reload
      # that does keep state must not crash boot.
      if registry.key?(name.to_s)
        Enliterator.logger&.warn("[enliterator] chat agent #{name.inspect} re-registered (overwriting prior definition)")
      end

      # Two nil-grounding agents make one unreachable (frontdesk returns whichever
      # registered first) and break routing. Reject the second loudly.
      if grounding.nil? && registry.values.any? { |a| a.grounding.nil? && a.name != name.to_s }
        raise Enliterator::ConfigurationError,
              "a Frontdesk agent (nil grounding) is already registered; only one is allowed"
      end

      registry[name.to_s] = Agent.new(
        name:          name.to_s,
        grounding:     grounding&.to_s,
        system_prompt: system_prompt,
        tools:         Array(tools).map(&:to_s),
        tier:          tier.to_s,
        routes_to:     Array(routes_to).map(&:to_s)
      )
    end

    # An agent definition. Immutable value object; all mutation goes through
    # the registry (register + reset!).
    class Agent
      attr_reader :name, :grounding, :system_prompt, :tools, :tier, :routes_to

      def initialize(name:, grounding:, system_prompt:, tools:, tier:, routes_to:)
        @name          = name
        @grounding     = grounding
        @system_prompt = system_prompt
        @tools         = tools
        @tier          = tier
        @routes_to     = routes_to
      end

      def allows?(tool_name) = tools.include?(tool_name.to_s)

      # The OpenAI function defs for this agent's tools, from the shared Mcp.listing,
      # filtered to the allow-list (read-only enforcement starts at what's offered).
      def tool_defs
        Enliterator::Mcp.listing.select { |t| allows?(t[:name]) }.map do |t|
          {
            "type"     => "function",
            "function" => {
              "name"        => t[:name],
              "description" => t[:description],
              "parameters"  => t[:inputSchema]
            }
          }
        end
      end
    end
  end
end
