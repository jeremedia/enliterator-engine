# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.28: the governed agentic loop. The LOOP — not the model — is the
    # enforcement boundary (allow-list before dispatch, grounding injection,
    # route_to interception). Events go to an injected sink (controller: SSE writer;
    # specs: an array). One turn per #run.
    class Loop
      ROUTE_TO = "route_to"

      def initialize(agent:, llm: nil, sink:, step_cap: 4, wall_budget: 90, clock: nil, context_resolver: nil)
        @agent   = agent
        # An injected adapter (specs) overrides per-tier resolution entirely; otherwise
        # resolve + cache one adapter PER TIER so a route_to to a higher-tier specialist
        # actually reasons on that tier (not the Frontdesk's memoized cheap adapter).
        @injected_llm = llm
        @sink    = sink
        @step_cap = step_cap
        @wall_budget = wall_budget
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        # Maps a context key → the value tools expect (the key string). Server-side,
        # never the cookie. Default: identity.
        @resolve = context_resolver || ->(key) { key }
      end

      # Drive the turn. Returns nothing meaningful; everything is emitted via the sink.
      def run(question)
        messages = [ { "role" => "system", "content" => @agent.system_prompt },
                     { "role" => "user", "content" => question.to_s } ]
        steps = 0
        started = @clock.call
        loop do
          # NOTE: the budget is checked BETWEEN rounds, not mid-call. A single slow
          # gateway call can exceed wall_budget by up to gateway_timeout (~180s);
          # Plan B sets a shorter per-call gateway_timeout upstream to bound that.
          if @clock.call - started > @wall_budget
            emit(:token, t: "I reached my time budget — here is what I have so far.")
            Enliterator.logger&.info("[enliterator] chat loop hit wall budget (#{@wall_budget}s) agent=#{@agent.name}")
            break
          end
          if steps >= @step_cap
            emit(:token, t: "I reached my step budget — here is what I have so far.")
            Enliterator.logger&.info("[enliterator] chat loop hit step cap (#{@step_cap}) agent=#{@agent.name}")
            break
          end
          steps += 1
          begin
            turn = llm.converse_with_tools(messages: messages, tools: tool_defs_with_route)
          rescue StandardError => e
            emit(:token, t: "I hit an error reaching the model — please try again.")
            Enliterator.logger&.warn("[enliterator] chat loop model error: #{e.class}: #{e.message}")
            break
          end
          if turn.tool_calls.empty?
            emit(:token, t: turn.text.to_s)
            break
          end
          messages << (turn.assistant_message || { "role" => "assistant", "content" => nil })
          handle_calls(turn.tool_calls, messages)
        end
        emit(:done, {})
      end

      private

      def llm
        return @injected_llm if @injected_llm
        (@llm_by_tier ||= {})[@agent.tier] ||= Enliterator.llm(tier: @agent.tier)
      end

      # route_to schema is injected here, never from Mcp.listing. Only for agents
      # that actually route.
      def tool_defs_with_route
        defs = @agent.tool_defs
        if @agent.routes_to.any?
          defs += [ { "type" => "function", "function" => {
            "name" => ROUTE_TO, "description" => "Hand off to a specialist desk.",
            "parameters" => { "type" => "object", "required" => [ "agent" ],
                              "properties" => { "agent" => { "type" => "string",
                                                             "enum" => @agent.routes_to } } } } } ]
        end
        defs
      end

      # Appends tool-result messages. route_to intercepted first; allow-list before
      # dispatch; context-bearing-only grounding.
      def handle_calls(calls, messages)
        calls.each do |call|
          # 1. route_to FIRST — intercepted, never dispatched.
          if call[:name] == ROUTE_TO
            target = call.dig(:arguments, "agent")
            agent = Enliterator::Chat.registry[target.to_s]
            if agent.nil?
              tool_error(call, messages, "cannot route to #{target.inspect}")
            else
              @agent = agent
              # The handoff must FULLY switch the desk: messages[0] carried the prior
              # agent's persona — replace it so the specialist reasons as itself this turn.
              messages[0] = { "role" => "system", "content" => @agent.system_prompt }
              emit(:handoff, to: agent.name)
              messages << tool_result_message(call, { routed_to: agent.name })
            end
            next
          end
          # 2. allow-list BEFORE dispatch (read-only enforcement).
          unless @agent.allows?(call[:name])
            tool_error(call, messages, "tool #{call[:name].inspect} is not available at this desk")
            next
          end
          # 3. grounding injection (context-bearing tools, model omitted).
          args = ground(call)
          # Start event precedes dispatch so a UI spinner spins WHILE the tool runs.
          emit(:tool_call_start, name: call[:name])
          begin
            result = Enliterator::Mcp.dispatch(call[:name], args)
            emit(:tool_call_result, name: call[:name], html: Enliterator::Chat::Widget.render(call[:name], result))
            messages << tool_result_message(call, result)
          rescue StandardError => e
            tool_error(call, messages, "couldn't consult #{call[:name]}: #{e.message}")
          end
        end
      end

      def ground(call)
        args = (call[:arguments] || {}).dup
        if @agent.grounding && !args.key?("context") && tool_takes_context?(call[:name])
          args["context"] = @resolve.call(@agent.grounding)
        end
        args
      end

      def tool_takes_context?(name)
        tool = Enliterator::Mcp.find_tool(name)
        tool && (tool.input_schema["properties"] || {}).key?("context")
      end

      def tool_result_message(call, result)
        { "role" => "tool", "tool_call_id" => call[:id], "content" => result.to_json }
      end

      def tool_error(call, messages, message)
        emit(:tool_call_error, name: call[:name], message: message)
        Enliterator.logger&.warn("[enliterator] chat tool error: #{message}")
        messages << tool_result_message(call, { error: message })
      end

      def emit(event, data) = @sink.call(event, data)
    end
  end
end
