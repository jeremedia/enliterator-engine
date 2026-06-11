module Enliterator
  module Mcp
    # The tool base: each tool declares a name, a description written FOR an
    # agent (what it's for, when to reach for it), and a plain JSON-Schema
    # input contract; `call(**args)` returns a Hash the controller serializes
    # as one text content block.
    #
    # House disciplines, applied to the agent as a consumer:
    # - BOUNDED: every collection capped, every long value truncated with a
    #   flag — the agent's context window is a budget exactly like the
    #   heartbeat's.
    # - SELF-DESCRIBING: responses carry `next` hints (which tool to call for
    #   depth, which /enliterator path shows a human the same thing) so no
    #   out-of-band knowledge is needed to act correctly.
    class Tool
      VALUE_MAX = 400

      class << self
        attr_reader :tool_name, :description, :input_schema

        def name_and_description(name, desc)
          @tool_name   = name
          @description = desc
        end

        def schema(properties = {}, required: [])
          @input_schema = {
            "type"       => "object",
            "properties" => properties,
            "required"   => required.map(&:to_s)
          }
        end

        # Shared property shorthands.
        def str(desc)  = { "type" => "string", "description" => desc }
        def int(desc)  = { "type" => "integer", "description" => desc }
      end

      private

      # Resolve an optional context KEY (MCP carries no cookies — scope is
      # explicit per call). Unknown keys raise an actionable message.
      def resolve_context(key)
        return nil if key.blank? || key.to_s == "root"
        Enliterator::Context.find_by(key: key.to_s) ||
          raise(ArgumentError,
                "unknown context #{key.inspect} — call collection_overview for the context tree")
      end

      # The status#show allowlist, agent-shaped: registered hosts ∪ Part.
      def find_record!(type, id)
        klass = type.to_s.safe_constantize
        unless Enliterator.tendable_type?(klass)
          raise ArgumentError,
                "unknown record type #{type.inspect} — collection_overview lists the tended types"
        end
        klass.find_by(klass.primary_key => id) ||
          raise(ArgumentError, "no #{type} with id #{id.inspect}")
      end

      def label_for(rec)
        rec.try(:title).presence || rec.try(:name).presence ||
          "#{rec.class.name} ##{rec.id}"
      end

      def render_value(value, cap: VALUE_MAX)
        s = value.is_a?(String) ? value : value.to_json
        s.length > cap ? "#{s[0, cap]}…" : s
      end

      def truncated?(value, cap: VALUE_MAX)
        s = value.is_a?(String) ? value : value.to_json
        s.length > cap
      end

      # One claim, with its provenance on its sleeve.
      def claim_card(claim, verdict: nil)
        {
          id:            claim.id,
          key:           claim.key,
          value:         render_value(claim.value),
          truncated:     truncated?(claim.value) || nil,
          confidence:    claim.confidence,
          tier:          claim.tier,
          status:        claim.status,
          locked:        claim.locked || nil,
          attributed_to: claim.attributed_to,
          context:       claim.context&.key || "root",
          audit_verdict: verdict
        }.compact
      end

      def entry_path(type, id) = "/enliterator/status/#{type}/#{id}"
    end
  end
end
