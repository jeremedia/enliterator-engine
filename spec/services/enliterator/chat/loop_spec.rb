# frozen_string_literal: true
require "rails_helper"

# v0.28 — the loop's enforcement boundary is the safety-critical surface.
RSpec.describe Enliterator::Chat::Loop do
  # A scripted adapter: returns queued ToolTurns in order. Each is either tool_calls
  # or final text.
  class ScriptedLLM
    TT = Enliterator::Adapters::LLM::Gateway::ToolTurn
    def initialize(*turns) = (@turns = turns)
    def converse_with_tools(messages:, tools:, **)
      t = @turns.shift
      t.is_a?(TT) ? t : TT.new(text: t.to_s, tool_calls: [], assistant_message: nil, tokens: {})
    end
  end
  def calls(*list) = Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
    text: nil, tool_calls: list, assistant_message: { "role" => "assistant", "tool_calls" => [] }, tokens: {})

  let(:events) { [] }
  let(:sink)   { ->(event, data) { events << [ event, data ] } }

  before do
    Enliterator::Chat.reset!
    allow(Enliterator).to receive(:llm).and_return(double(converse_with_tools: nil))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search provenance], tier: "cheap", routes_to: %w[CHDS])
    Enliterator::Chat.register(name: "CHDS", grounding: "chds-theses", system_prompt: "advise",
                               tools: %w[search provenance], tier: "cheap")
  end
  after { Enliterator::Chat.reset! }

  def run(llm, agent: Enliterator::Chat.frontdesk)
    described_class.new(agent: agent, llm: llm, sink: sink, step_cap: 4).run("hello")
  end

  it "REFUSES a tool not on the active agent's allow-list, before dispatch (read-only enforcement)" do
    expect(Enliterator::Mcp).not_to receive(:dispatch)
    run(ScriptedLLM.new(calls({ id: "1", name: "flag_claim", arguments: {} }), "done"))
    expect(events.map(&:first)).to include(:tool_call_error)
    err = events.find { |e| e.first == :tool_call_error }
    expect(err.last[:message]).to match(/not (allowed|available)/i)
  end

  it "intercepts route_to FIRST (never dispatches it) and switches the active agent" do
    expect(Enliterator::Mcp).not_to receive(:dispatch)
    run(ScriptedLLM.new(calls({ id: "1", name: "route_to", arguments: { "agent" => "CHDS" } }), "now at CHDS"))
    handoff = events.find { |e| e.first == :handoff }
    expect(handoff.last[:to]).to eq("CHDS")
  end

  it "after route_to in the same batch, later tools are checked against the NEW agent" do
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ results: [] })
    run(ScriptedLLM.new(
      calls({ id: "1", name: "route_to", arguments: { "agent" => "CHDS" } },
            { id: "2", name: "search", arguments: { "q" => "x" } }), "done"))
    expect(events.map(&:first)).to include(:handoff, :tool_call_result)
    expect(events.map(&:first)).not_to include(:tool_call_error)   # search allowed at CHDS
  end

  it "injects the desk context only for context-bearing tools the model left unscoped" do
    captured = []
    allow(Enliterator::Mcp).to receive(:dispatch) { |name, args| captured << [ name, args ]; { label: "x" } }
    chds = Enliterator::Chat.for_context("chds-theses")
    # search HAS context; provenance does NOT
    run(ScriptedLLM.new(calls({ id: "1", name: "search", arguments: { "q" => "x" } },
                              { id: "2", name: "provenance", arguments: { "claim_id" => 5 } }), "done"),
        agent: chds)
    search_args = captured.find { |c| c.first == "search" }.last
    prov_args   = captured.find { |c| c.first == "provenance" }.last
    expect(search_args["context"]).to eq("chds-theses")   # injected (omitted + context-bearing)
    expect(prov_args).not_to have_key("context")          # NOT injected (no context property)
  end

  it "honors a model-supplied context (the 'not walled' widen)" do
    captured = []
    allow(Enliterator::Mcp).to receive(:dispatch) { |name, args| captured << args; { label: "x" } }
    chds = Enliterator::Chat.for_context("chds-theses")
    run(ScriptedLLM.new(calls({ id: "1", name: "search", arguments: { "q" => "x", "context" => "crs-reports" } }), "done"), agent: chds)
    expect(captured.first["context"]).to eq("crs-reports")
  end

  it "emits a tool_call_result (widget) and feeds the result back, ending on the final answer" do
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ results: [ { label: "A Thesis", type: "thesis", excerpt: "found" } ] })
    run(ScriptedLLM.new(calls({ id: "1", name: "search", arguments: { "q" => "x" } }), "Here is what I found."))
    widget = events.find { |e| e.first == :tool_call_result }
    expect(widget.last[:html]).to include("A Thesis")
    expect(events.last).to eq([ :done, {} ])
  end

  it "gives a routed-to specialist its OWN step budget — triage must not consume the desk's working room" do
    # Frontdesk spends 2 of 4 steps (a tool call, then route_to). The specialist
    # then needs 3 tool rounds before composing — which would BLOW a shared cap of
    # 4, but completes because the handoff resets the budget. (Acyclic topology +
    # the wall budget are the runaway backstops; the step budget is per-desk.)
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ results: [] })
    run(ScriptedLLM.new(
      calls({ id: "1", name: "search",   arguments: { "q" => "x" } }),         # Frontdesk step 1
      calls({ id: "2", name: "route_to", arguments: { "agent" => "CHDS" } }),  # Frontdesk step 2 → handoff (reset)
      calls({ id: "3", name: "search",   arguments: { "q" => "a" } }),         # CHDS step 1
      calls({ id: "4", name: "search",   arguments: { "q" => "b" } }),         # CHDS step 2
      calls({ id: "5", name: "search",   arguments: { "q" => "c" } }),         # CHDS step 3
      "Here is my recommendation."))                                           # CHDS final answer
    final = events.reverse.find { |e| e.first == :token }
    expect(final.last[:t]).to eq("Here is my recommendation.")
    expect(events.find { |e| e.first == :token && e.last[:t].to_s.match?(/step budget/i) }).to be_nil
    expect(events.last).to eq([ :done, {} ])
  end

  it "stops at the step cap with a visible budget message (rule 3), never silently" do
    looping = Array.new(10) { calls({ id: "1", name: "search", arguments: { "q" => "x" } }) }
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ label: "x", claims_by_facet: {} })
    run(ScriptedLLM.new(*looping))
    budget = events.find { |e| e.first == :token && e.last[:t].to_s.match?(/step budget/i) }
    expect(budget).not_to be_nil
    expect(events.last).to eq([ :done, {} ])
  end

  describe "v0.35 follow-ups (config.chat_followups)" do
    let(:answer_with_tail) do
      "Here is the answer.\n\n#{Enliterator::Chat::Followups::SENTINEL}\nWhat changed?\nWho cited it?"
    end

    def fake_llm(text)
      Class.new do
        define_method(:converse_with_tools) do |messages:, tools:, stream: false, **|
          @seen = messages
          Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
            text: text, tool_calls: [], assistant_message: nil, tokens: {})
        end
        attr_reader :seen
      end.new
    end

    # Real Chat::Agent.new signature: name:, grounding:, system_prompt:, tools:, tier:, routes_to:
    let(:agent) do
      Enliterator::Chat::Agent.new(
        name: "Desk", grounding: nil, system_prompt: "You are the Desk.",
        tools: %w[search], tier: "cheap", routes_to: [])
    end

    it "with the flag ON, injects the directive into the system prompt and emits :followups" do
      Enliterator.configuration.chat_followups = true
      llm = fake_llm(answer_with_tail)
      events = []
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(e, d) { events << [ e, d ] }).run("hi")
      expect(llm.seen.first["content"]).to include(Enliterator::Chat::Followups::SENTINEL)
      fu = events.find { |e, _| e == :followups }
      expect(fu).not_to be_nil
      expect(fu.last[:items]).to eq([ "What changed?", "Who cited it?" ])
    ensure
      Enliterator.configuration.chat_followups = nil
    end

    it "with the flag OFF (default), injects NO directive and emits NO :followups (byte-identical)" do
      llm = fake_llm(answer_with_tail)
      events = []
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(e, d) { events << [ e, d ] }).run("hi")
      expect(llm.seen.first["content"]).not_to include(Enliterator::Chat::Followups::SENTINEL)
      expect(events.map(&:first)).not_to include(:followups)
    end

    it "with the flag ON but the model omits the block, emits NO :followups" do
      Enliterator.configuration.chat_followups = true
      llm = fake_llm("A plain answer with no block.")
      events = []
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(e, d) { events << [ e, d ] }).run("hi")
      expect(events.map(&:first)).not_to include(:followups)
    ensure
      Enliterator.configuration.chat_followups = nil
    end

    # The handoff is the federation path's core mechanic: the directive must be
    # RE-applied when a specialist takes over, or the answering desk never emits a
    # block and follow-ups silently vanish. Frontdesk "F" routes to "CHDS"; CHDS
    # (system_prompt "advise") produces the final answer — assert the system prompt
    # IT saw is its own persona PLUS the directive (proving system_content ran at the
    # handoff reset, on the specialist, not the Frontdesk).
    it "re-applies the directive after a handoff (the specialist that answers carries it)" do
      Enliterator.configuration.chat_followups = true
      seen_on_final = nil
      turns = [ calls({ id: "1", name: "route_to", arguments: { "agent" => "CHDS" } }), answer_with_tail ]
      llm = Object.new
      llm.define_singleton_method(:converse_with_tools) do |messages:, tools:, stream: false, **|
        t = turns.shift
        next t if t.is_a?(Enliterator::Adapters::LLM::Gateway::ToolTurn) # the route_to turn
        seen_on_final = messages.first["content"]                        # the final-answer turn
        Enliterator::Adapters::LLM::Gateway::ToolTurn.new(text: t, tool_calls: [], assistant_message: nil, tokens: {})
      end
      events = []
      Enliterator::Chat::Loop.new(agent: Enliterator::Chat.frontdesk, llm: llm,
                                  sink: ->(e, d) { events << [ e, d ] }, step_cap: 4).run("hi")
      expect(seen_on_final).to include("advise")                                   # the SPECIALIST's persona
      expect(seen_on_final).to include(Enliterator::Chat::Followups::SENTINEL)     # ...plus the directive
      expect(events.map(&:first)).to include(:handoff, :followups)
    ensure
      Enliterator.configuration.chat_followups = nil
    end
  end
end
