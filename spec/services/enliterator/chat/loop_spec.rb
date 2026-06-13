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
end
