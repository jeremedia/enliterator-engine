# frozen_string_literal: true

module Enliterator
  module Chat
    # An agent definition. Immutable value object; all mutation goes through
    # the registry (Enliterator::Chat.register + .reset!, defined in chat.rb).
    class Agent
      attr_reader :name, :grounding, :system_prompt, :tools, :tier, :routes_to, :step_cap

      def initialize(name:, grounding:, system_prompt:, tools:, tier:, routes_to:, step_cap: nil)
        @name          = name
        @grounding     = grounding
        @system_prompt = system_prompt
        @tools         = tools
        @tier          = tier
        @routes_to     = routes_to
        @step_cap      = step_cap
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
