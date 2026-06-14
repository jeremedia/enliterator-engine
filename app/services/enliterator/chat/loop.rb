# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.28: the governed agentic loop. The LOOP — not the model — is the
    # enforcement boundary (allow-list before dispatch, grounding injection,
    # route_to interception). Events go to an injected sink (controller: SSE writer;
    # specs: an array). One turn per #run.
    class Loop
      ROUTE_TO = "route_to"

      def initialize(agent:, llm: nil, sink:, step_cap: 4, wall_budget: 90, clock: nil, context_resolver: nil,
                     error_detail: Enliterator.configuration.error_detail?)
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
        # v0.30: gates whether the emitted :error / :tool_call_error payloads carry
        # ACTIONABLE detail (class/message, where, hint) past the generic floor. The
        # default reads the resolver (dev-on) so existing callers/tests get the right
        # behavior; the controller passes it explicitly per-request in a later task.
        @error_detail = error_detail
      end

      # Drive the turn. Returns nothing meaningful; everything is emitted via the sink.
      def run(question)
        messages = [ { "role" => "system", "content" => system_content },
                     { "role" => "user", "content" => question.to_s } ]
        # @steps is the CURRENT desk's step budget — reset on handoff (see handle_calls),
        # so a Frontdesk's triage never charges against the specialist's working room.
        # The wall-clock budget below (from turn start, never reset) and the acyclic
        # routing topology are the runaway backstops.
        @steps = 0
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
          if @steps >= effective_step_cap
            emit(:token, t: "I reached my step budget — here is what I have so far.")
            Enliterator.logger&.info("[enliterator] chat loop hit step cap (#{effective_step_cap}) agent=#{@agent.name}")
            break
          end
          @steps += 1
          # v0.33: stream the final answer token-by-token. The adapter fires the block
          # per content delta; `streamed` records whether it did, so a real streaming
          # round (block fired) does NOT also emit the lumped final text — while a
          # non-streaming adapter (or the test ScriptedLLM, which ignores the block)
          # leaves `streamed` false and the full text is emitted as before.
          streamed = false
          begin
            turn = llm.converse_with_tools(messages: messages, tools: tool_defs_with_route, stream: true) do |delta|
              streamed = true
              emit(:token, t: delta)
            end
          rescue StandardError => e
            emit(:error, Enliterator::Chat::ErrorReport.build(
              e, where: { stage: "model call", agent: @agent.name, tier: @agent.tier },
              detail: @error_detail, message: "I hit an error reaching the model — please try again."))
            Enliterator.logger&.warn("[enliterator] chat loop model error: #{e.class}: #{e.message}")
            break
          end
          if turn.tool_calls.empty?
            emit(:token, t: turn.text.to_s) unless streamed
            emit_followups(turn.text) if Enliterator.configuration.chat_followups
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
              messages[0] = { "role" => "system", "content" => system_content }
              emit(:handoff, to: agent.name)
              messages << tool_result_message(call, { routed_to: agent.name })
              # The specialist gets its OWN step budget — the patron's triage at the
              # Frontdesk must not eat the desk's room to actually work. Routing is a
              # separate phase, not a charge against advising. (Acyclic topology today:
              # specialists carry empty routes_to, so this resets at most once; the wall
              # budget bounds any future bidirectional federation regardless. When
              # bidirectional routing lands, add a handoff ceiling here, tested with it.)
              @steps = 0
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
            # Floor message is STATIC (no e.message) so a tool failure never leaks the
            # raw exception in prod via :tool_call_error — the exception goes ONLY into
            # the error_detail-gated detail/hint (built from `error:` inside tool_error).
            tool_error(call, messages, "couldn't consult #{call[:name]}.", error: e)
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

      # The terminal event for a tool that could not be honored. `message` is the
      # generic floor (always emitted, never derived from the exception). When an
      # `error` is given AND detail is enabled, the actionable fields (detail/where/
      # hint) from ErrorReport are merged in — MINUS its :message, since the floor
      # message already stands. The allow-list rejection passes no `error:` (no
      # exception to detail), so it stays message-only even in dev.
      def tool_error(call, messages, message, error: nil)
        payload = { name: call[:name], message: message }
        if @error_detail && error
          rep = Enliterator::Chat::ErrorReport.build(
            error, where: { stage: "tool", tool: call[:name] }, detail: true, message: message)
          payload.merge!(rep.slice(:detail, :where, :hint))
        end
        emit(:tool_call_error, **payload)
        Enliterator.logger&.warn("[enliterator] chat tool error: #{message}")
        messages << tool_result_message(call, { error: message })
      end

      # System content for the active agent: the engine register + the EFFECTIVE
      # persona (curator override if stored, else the registered seed) + the
      # follow-up directive. Resolved at turn time so a persona edit is live
      # without a restart. Composition lives in Chat.compose_system (shared with
      # the /desks preview).
      def system_content
        Enliterator::Chat.compose_system(persona_for(@agent))
      end

      # The effective persona text for an agent: a curator's stored override wins;
      # otherwise the registered seed ("code seeds, store governs").
      def persona_for(agent)
        Enliterator::Chat::Persona.effective(agent.name) || agent.system_prompt
      end

      # v0.35: parse the answer's trailing %%FOLLOWUPS%% block and surface the
      # questions as a structured event (the client renders them as buttons). The
      # raw tail still rides in the :token stream — the client strips it for display;
      # this event is the authoritative button source. Always log the outcome so the
      # experiment can measure emission reliability (rule 3: emitted=false is logged too).
      def emit_followups(text)
        items = Enliterator::Chat::Followups.parse(text)
        emit(:followups, items: items) if items.any?
        Enliterator.logger&.info(
          "[enliterator] followups agent=#{@agent.name} emitted=#{items.any?} " \
          "count=#{items.size} items=#{items.inspect}")
      end

      def emit(event, data) = @sink.call(event, data)

      # The active desk's step budget: a per-agent cap (set at registration) wins;
      # otherwise the constructor default (@step_cap). Recomputed each round so a
      # handoff to a desk with a different cap takes effect immediately.
      def effective_step_cap = @agent.step_cap || @step_cap
    end
  end
end
