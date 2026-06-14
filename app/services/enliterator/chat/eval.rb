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
      # record: defaults to config.chat_retention; when truthy, persists the turn
      # to a source:"eval" Conversation (never raises — rule 3).
      def self.ask(question, context: nil, record: Enliterator.configuration.chat_retention,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, **loop_opts)
        agent  = Enliterator::Chat.for_context(context)
        events = []
        t0 = clock.call
        Enliterator::Chat::Loop.new(agent: agent, sink: ->(ev, d) { events << [ ev, d ] }, **loop_opts).run(question)
        elapsed = (clock.call - t0).round(1)
        # Persist when retention is on. Events are [[symbol_ev, data], ...] —
        # convert to the {"event"=>string, "data"=>data} shape Recorder expects.
        if record
          captured = events.map { |ev, d| { "event" => ev.to_s, "data" => d } }
          conv = Enliterator::Chat::Conversation.find_or_create_by(token: SecureRandom.uuid) do |c|
            c.context = context
            c.source  = "eval"
          end
          Enliterator::Chat::Recorder.record(
            conversation: conv, question: question.to_s, events: captured,
            initial_desk: agent.name, elapsed_ms: (elapsed * 1000).round)
        end
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
