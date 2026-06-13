# frozen_string_literal: true
require "rails_helper"

# v0.33 — the loop streams the final answer token-by-token. When the adapter fires
# its block (real streaming), each delta is emitted as its own :token event and the
# loop does NOT also emit the lumped final text (the `unless streamed` guard). The
# ScriptedLLM in loop_spec ignores the block, exercising the non-streaming fallback.
RSpec.describe Enliterator::Chat::Loop do
  TT = Enliterator::Adapters::LLM::Gateway::ToolTurn

  # A streaming adapter: invokes the block with each canned delta, then returns the
  # text-only ToolTurn (no tool calls) — exactly the gateway's content-only stream path.
  class StreamingLLM
    def initialize(*deltas) = (@deltas = deltas)
    def converse_with_tools(messages:, tools:, stream: false, &block)
      if stream && block
        @deltas.each { |d| block.call(d) }
        TT.new(text: @deltas.join, tool_calls: [], assistant_message: nil, tokens: {})
      else
        TT.new(text: @deltas.join, tool_calls: [], assistant_message: nil, tokens: {})
      end
    end
  end

  let(:events) { [] }
  let(:sink)   { ->(event, data) { events << [ event, data ] } }

  before do
    Enliterator::Chat.reset!
    allow(Enliterator).to receive(:llm).and_return(double(converse_with_tools: nil))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search provenance], tier: "cheap")
  end
  after { Enliterator::Chat.reset! }

  it "emits one :token per streamed delta (not a single lump) and ends on :done" do
    described_class.new(agent: Enliterator::Chat.frontdesk,
                        llm: StreamingLLM.new("Hel", "lo."), sink: sink, step_cap: 4).run("hello")

    tokens = events.select { |e| e.first == :token }.map { |e| e.last[:t] }
    expect(tokens).to eq(%w[Hel lo.])           # streamed, not ["Hello."]
    expect(events.last).to eq([ :done, {} ])
  end
end
