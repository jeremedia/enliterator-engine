# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Loop do
  TT = Enliterator::Adapters::LLM::Gateway::ToolTurn
  def calls(*list) = TT.new(text: nil, tool_calls: list,
                            assistant_message: { "role" => "assistant", "tool_calls" => [] }, tokens: {})

  before do
    Enliterator::Chat.reset!
    allow(Enliterator).to receive(:llm).and_return(double(converse_with_tools: nil))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p", tools: %w[search], tier: "cheap")
  end
  after { Enliterator::Chat.reset! }

  it "stops with a visible time-budget message when the per-turn wall-clock budget is exceeded" do
    events = []
    # A clock returning +40s each call; budget 60s ⇒ exceeded after ~1 round.
    t = 0.0
    clock = -> { t += 40 }
    looping = Object.new
    def looping.converse_with_tools(**)
      Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
        text: nil, tool_calls: [ { id: "1", name: "search", arguments: { "q" => "x" } } ],
        assistant_message: { "role" => "assistant", "tool_calls" => [] }, tokens: {})
    end
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ results: [] })
    described_class.new(agent: Enliterator::Chat.frontdesk, llm: looping,
                        sink: ->(e, d) { events << [ e, d ] }, step_cap: 20, wall_budget: 60, clock: clock).run("hi")
    budget = events.find { |e| e.first == :token && e.last[:t].to_s.match?(/time budget/i) }
    expect(budget).not_to be_nil
    expect(events.last).to eq([ :done, {} ])
  end

  it "turns a gateway/adapter raise mid-loop into a VISIBLE terminal event + :done (never propagates)" do
    events = []
    boom = Object.new
    def boom.converse_with_tools(**) = raise(StandardError, "gateway 500")
    expect {
      described_class.new(agent: Enliterator::Chat.frontdesk, llm: boom,
                          sink: ->(e, d) { events << [ e, d ] }).run("hi")
    }.not_to raise_error
    err = events.find { |e| e.first == :token && e.last[:t].to_s.match?(/error/i) } ||
          events.find { |e| e.first == :tool_call_error }
    expect(err).not_to be_nil
    expect(events.last).to eq([ :done, {} ])
  end
end
