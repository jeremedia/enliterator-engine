# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.38: drive the reference desk from code (no browser). Runs one turn through
    # the real Chat::Loop (real agents, gateway, tools, persona/register) and returns
    # a structured Result — the evaluation/dogfooding harness behind `enliterator:ask`.
    module Eval
      Result = Struct.new(:question, :context, :answer, :tools, :handoffs, :followups,
                          :elapsed_s, :budget_hit, :events, keyword_init: true)

      # Ask the desk a question. context: a grounding key (nil => Frontdesk). Extra
      # loop_opts (e.g. step_cap:) pass through to Chat::Loop. Returns a Result.
      def self.ask(question, context: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, **loop_opts)
        agent  = Enliterator::Chat.for_context(context)
        events = []
        t0 = clock.call
        Enliterator::Chat::Loop.new(agent: agent, sink: ->(ev, d) { events << [ ev, d ] }, **loop_opts).run(question)
        elapsed = (clock.call - t0).round(1)
        raw   = events.select { |e| e.first == :token }.map { |e| e.last[:t] }.join
        prose = raw.split(Enliterator::Chat::Followups::SENTINEL).first.to_s.strip
        Result.new(
          question: question, context: context, answer: prose,
          tools:     events.select { |e| e.first == :tool_call_start }.map { |e| e.last[:name] },
          handoffs:  events.select { |e| e.first == :handoff }.map { |e| e.last[:to] },
          followups: events.select { |e| e.first == :followups }.flat_map { |e| e.last[:items] },
          elapsed_s: elapsed,
          budget_hit: prose.include?("step budget") || prose.include?("time budget"),
          events: events)
      end
    end
  end
end
