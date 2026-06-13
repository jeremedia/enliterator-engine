# frozen_string_literal: true
require "rails_helper"

# v0.30 — the loop's error emission, gated by error_detail. The model-call rescue
# now emits a structured :error event; the tool/allow-list paths emit :tool_call_error.
# Detail (class/message · where · hint) appears ONLY when error_detail is on AND an
# actual exception is in hand; the generic `message` is always the static floor.
RSpec.describe Enliterator::Chat::Loop do
  # A scripted adapter mirroring loop_spec's harness: queued ToolTurns in order.
  class ScriptedErrLLM
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
                               tools: %w[search provenance], tier: "cheap")
  end
  after { Enliterator::Chat.reset! }

  # A gateway that raises with a timeout-shaped message so a hint matches.
  def boom(msg = "Net::ReadTimeout: execution timed out")
    o = Object.new
    o.define_singleton_method(:converse_with_tools) { |**| raise(StandardError, msg) }
    o
  end

  describe "model-call raise" do
    it "with error_detail: true emits a structured :error carrying detail + hint, message stays the generic literal" do
      described_class.new(agent: Enliterator::Chat.frontdesk, llm: boom,
                          sink: sink, error_detail: true).run("hi")
      err = events.find { |e| e.first == :error }
      expect(err).not_to be_nil
      payload = err.last
      expect(payload[:message]).to eq("I hit an error reaching the model — please try again.")
      expect(payload).to have_key(:detail)
      expect(payload).to have_key(:hint)
      expect(payload[:detail]).to match(/timed out/i)
      expect(payload[:hint]).to match(/timed out|gateway/i)
      # the floor message is NEVER the exception's own message
      expect(payload[:message]).not_to match(/ReadTimeout/)
      expect(events.last).to eq([ :done, {} ])
    end

    it "with error_detail: false emits an :error whose payload is {message:} ONLY (no detail/where/hint leak)" do
      described_class.new(agent: Enliterator::Chat.frontdesk, llm: boom,
                          sink: sink, error_detail: false).run("hi")
      err = events.find { |e| e.first == :error }
      expect(err).not_to be_nil
      expect(err.last).to eq({ message: "I hit an error reaching the model — please try again." })
      expect(err.last.keys).to eq([ :message ])
      expect(events.last).to eq([ :done, {} ])
    end
  end

  describe "allow-list rejection (no exception to detail)" do
    it "with error_detail: true emits :tool_call_error with message but NO :detail key" do
      described_class.new(agent: Enliterator::Chat.frontdesk, llm: ScriptedErrLLM.new(
        calls({ id: "1", name: "flag_claim", arguments: {} }), "done"),
                          sink: sink, error_detail: true).run("hi")
      err = events.find { |e| e.first == :tool_call_error }
      expect(err).not_to be_nil
      expect(err.last[:message]).to match(/not (allowed|available)/i)
      expect(err.last).not_to have_key(:detail)
      expect(err.last).not_to have_key(:hint)
      expect(events.last).to eq([ :done, {} ])
    end
  end

  describe "tool dispatch raise (exception present)" do
    it "with error_detail: true merges detail/where/hint into :tool_call_error, message stays the consult floor" do
      allow(Enliterator::Mcp).to receive(:dispatch).and_raise(StandardError, "Net::ReadTimeout: execution timed out")
      described_class.new(agent: Enliterator::Chat.frontdesk, llm: ScriptedErrLLM.new(
        calls({ id: "1", name: "search", arguments: { "q" => "x" } }), "done"),
                          sink: sink, error_detail: true).run("hi")
      err = events.find { |e| e.first == :tool_call_error }
      expect(err).not_to be_nil
      expect(err.last[:message]).to match(/couldn't consult search/)
      expect(err.last).to have_key(:detail)
      expect(err.last).to have_key(:hint)
      expect(events.last).to eq([ :done, {} ])
    end

    it "with error_detail: false emits :tool_call_error message-only (no detail leak from the exception)" do
      allow(Enliterator::Mcp).to receive(:dispatch).and_raise(StandardError, "Net::ReadTimeout: execution timed out")
      described_class.new(agent: Enliterator::Chat.frontdesk, llm: ScriptedErrLLM.new(
        calls({ id: "1", name: "search", arguments: { "q" => "x" } }), "done"),
                          sink: sink, error_detail: false).run("hi")
      err = events.find { |e| e.first == :tool_call_error }
      expect(err).not_to be_nil
      expect(err.last).not_to have_key(:detail)
      expect(err.last).not_to have_key(:hint)
      expect(events.last).to eq([ :done, {} ])
    end
  end
end
