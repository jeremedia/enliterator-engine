# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Eval do
  TT = Enliterator::Adapters::LLM::Gateway::ToolTurn

  # A fake adapter that returns queued ToolTurns in order. Accepts the stream:
  # keyword and optional block that Loop passes; ignores them.
  class FakeEvalLLM
    def initialize(*turns) = (@turns = turns)
    def converse_with_tools(messages:, tools:, stream: false, **) = @turns.shift
  end

  before do
    Enliterator::Chat.reset!
    # Stub tier resolution so register's fail-fast validation passes.
    allow(Enliterator).to receive(:llm).and_return(FakeEvalLLM.new)
    Enliterator::Chat.register(name: "Frontdesk", grounding: nil, system_prompt: "You help.",
                               tools: %w[search], tier: "cheap")
  end
  after { Enliterator::Chat.reset! }

  it "returns a Result with the answer and timing extracted from the events" do
    text = "The collection holds X."
    llm  = FakeEvalLLM.new(TT.new(text: text, tool_calls: [], assistant_message: nil, tokens: {}))
    allow(Enliterator).to receive(:llm).and_return(llm)

    times = [ 100.0, 101.5 ]
    res = described_class.ask("hi", clock: -> { times.shift })

    expect(res.question).to eq("hi")
    expect(res.answer).to eq("The collection holds X.")
    expect(res.elapsed_s).to eq(1.5)
    expect(res.tools).to be_empty
    expect(res.handoffs).to be_empty
    expect(res.followups).to be_empty
    expect(res.budget_hit).to be(false)
    expect(res.context).to be_nil
  end

  it "strips the SENTINEL tail and surfaces followups as structured items" do
    Enliterator.configuration.chat_followups = true
    text = "The collection holds X.\n\n#{Enliterator::Chat::Followups::SENTINEL}\nWhat about Y?\nAnd Z?"
    llm  = FakeEvalLLM.new(TT.new(text: text, tool_calls: [], assistant_message: nil, tokens: {}))
    allow(Enliterator).to receive(:llm).and_return(llm)

    times = [ 0.0, 2.3 ]
    res = described_class.ask("hi", clock: -> { times.shift })

    expect(res.answer).to eq("The collection holds X.")
    expect(res.followups).to eq([ "What about Y?", "And Z?" ])
    expect(res.elapsed_s).to eq(2.3)
    expect(res.budget_hit).to be(false)
  ensure
    Enliterator.configuration.chat_followups = nil
  end

  it "sets budget_hit when the answer contains the step budget message" do
    text = "I reached my step budget — here is what I have so far."
    llm  = FakeEvalLLM.new(TT.new(text: text, tool_calls: [], assistant_message: nil, tokens: {}))
    allow(Enliterator).to receive(:llm).and_return(llm)

    res = described_class.ask("hi", clock: -> { 0.0 })
    expect(res.budget_hit).to be(true)
  end

  it "records tool names from tool_call_start events" do
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ label: "x", claims_by_facet: {} })
    tool_turn = TT.new(
      text: nil,
      tool_calls: [ { id: "1", name: "search", arguments: { "q" => "x" } } ],
      assistant_message: { "role" => "assistant", "tool_calls" => [] },
      tokens: {}
    )
    final_turn = TT.new(text: "Here is what I found.", tool_calls: [], assistant_message: nil, tokens: {})
    llm = FakeEvalLLM.new(tool_turn, final_turn)
    allow(Enliterator).to receive(:llm).and_return(llm)

    res = described_class.ask("hi", clock: -> { 0.0 })
    expect(res.tools).to eq([ "search" ])
    expect(res.answer).to eq("Here is what I found.")
  end
end
