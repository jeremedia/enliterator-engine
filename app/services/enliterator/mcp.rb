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
  # never a hand that edits the record. v0.69 does not change that — see
  # #host_tool_classes: a host tool acts on the HOST's data, never the record.
  #
  # The registry is an explicit list (boot-order-proof — descendants
  # scanning depends on eager loading), plus (v0.69) any tools the host has
  # registered. Dispatch validates arguments against each tool's declared JSON
  # Schema (required keys + primitive types — the ~30 lines we need, no
  # dependency).
  module Mcp
    module_function

    class InvalidArguments < StandardError; end

    # The engine's own tools, in listing order. An explicit list, not a
    # descendants scan — see the boot-order note above.
    def builtin_tool_classes
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

    # v0.69: tools the HOST contributes.
    #
    # The engine's tools read the collection; a host application also has
    # actions of its own that belong in the same conversation — HSDL's research
    # carrel is the first, where a patron asks the desk to keep a summary. The
    # host owns that behaviour and its storage, so it owns the tool.
    #
    # This does NOT loosen the doctrine at the top of this file. Writes still
    # never touch the record: a host tool acts on the HOST's data (a patron's
    # own library), and the governed loops remain the only path into the
    # collection. A host that registers a corpus-editing tool is defeating the
    # design, not extending it.
    #
    # Mirrors Measures.register / Condition.register, the engine's existing
    # host-extension registries: register inside the host's `to_prepare` after
    # a reset, so a Zeitwerk reload cannot leave a stale class constant here.
    def host_tool_classes
      @host_tool_classes ||= []
    end

    # Register a host tool class. Validates NOW rather than letting a bad tool
    # silently vanish from the listing (a tool that is merely absent is
    # invisible to debug — the model just never calls it).
    def register(klass)
      %i[tool_name description input_schema].each do |m|
        unless klass.respond_to?(m)
          raise Enliterator::ConfigurationError,
                "host MCP tool #{klass.inspect} does not respond to .#{m} — " \
                "subclass Enliterator::Mcp::Tool"
        end
      end

      name = klass.tool_name.to_s
      raise Enliterator::ConfigurationError, "host MCP tool #{klass.inspect} has a blank tool_name" if name.empty?

      if builtin_tool_classes.any? { |t| t.tool_name.to_s == name }
        raise Enliterator::ConfigurationError,
              "host MCP tool #{name.inspect} collides with an engine tool — pick another name"
      end

      # Re-registration is the normal case across a dev reload; replace rather
      # than duplicate so the listing cannot grow on every request.
      host_tool_classes.reject! { |t| t.tool_name.to_s == name }
      host_tool_classes << klass
      klass
    end

    # Drop all host tools. The host calls this before re-registering, exactly
    # as it calls Chat.reset! before re-registering agents.
    def reset_host_tools!
      @host_tool_classes = []
    end

    # Builtins first, always, in their original order: with no host tool
    # registered this returns byte-identical output to every prior version.
    def tool_classes
      builtin_tool_classes + host_tool_classes
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
