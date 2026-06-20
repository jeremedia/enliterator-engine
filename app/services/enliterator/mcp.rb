module Enliterator
  # v0.26: the MCP surface — the agent's reading-room card.
  #
  # What an enliterated collection uniquely offers an agent is PROVENANCE,
  # TRAJECTORY, and SELF-KNOWLEDGE: tools that let a conversational agent
  # calibrate its confidence sentence by sentence ("authorship claims here
  # audit at 95% supported"; "the collection revised this after reading the
  # whole thesis") instead of hedging uniformly. Nearly every tool is a thin
  # projection over an existing cached service — the brains were built in
  # v0.6–v0.25; this is the agent-shaped hands.
  #
  # Writes go ONLY through the governed loops (the suggestions queue, the
  # review queue): the agent is another patron and another set of eyes,
  # never a hand that edits the record.
  #
  # The registry is an explicit list (boot-order-proof — descendants
  # scanning depends on eager loading). Dispatch validates arguments against
  # each tool's declared JSON Schema (required keys + primitive types — the
  # ~30 lines we need, no dependency).
  module Mcp
    module_function

    class InvalidArguments < StandardError; end

    def tool_classes
      [
        Tools::CollectionOverview,
        Tools::Vocabulary,
        Tools::Search,
        Tools::BrowseSubjects,
        Tools::SubjectSearch,
        Tools::RecordEntry,
        Tools::Connections,
        Tools::Trajectory,
        Tools::Provenance,
        Tools::Quote,
        Tools::Accuracy,
        Tools::RecentActivity,
        Tools::Lacunae,
        Tools::ProposeTerm,
        Tools::FlagClaim
      ]
    end

    def find_tool(name)
      tool_classes.find { |t| t.tool_name == name.to_s }
    end

    # The tools/list payload.
    def listing
      tool_classes.map do |t|
        { name: t.tool_name, description: t.description, inputSchema: t.input_schema }
      end
    end

    # Validate + run one tool. Raises InvalidArguments for schema misses
    # (the controller maps it to -32602); tool-internal failures raise and
    # the controller renders them as isError results.
    def dispatch(name, args)
      tool = find_tool(name)
      raise InvalidArguments, "unknown tool #{name.inspect}" if tool.nil?
      args = (args || {}).transform_keys(&:to_s)
      validate!(tool.input_schema, args)
      tool.new.call(**args.symbolize_keys)
    end

    # Minimal JSON-Schema check: required keys present, declared properties
    # type-checked (string/integer/number/boolean), unknown keys rejected.
    def validate!(schema, args)
      props    = schema["properties"] || {}
      required = Array(schema["required"])

      missing = required - args.keys
      raise InvalidArguments, "missing required argument(s): #{missing.join(', ')}" if missing.any?

      unknown = args.keys - props.keys
      raise InvalidArguments, "unknown argument(s): #{unknown.join(', ')}" if unknown.any?

      args.each do |key, value|
        expected = props.dig(key, "type")
        next if expected.nil?
        ok =
          case expected
          when "string"  then value.is_a?(String)
          when "integer" then value.is_a?(Integer)
          when "number"  then value.is_a?(Numeric)
          when "boolean" then [ true, false ].include?(value)
          else true
          end
        raise InvalidArguments, "#{key} must be a #{expected}" unless ok
      end
    end
  end
end
