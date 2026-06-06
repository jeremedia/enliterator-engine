require "rails_helper"

# The Null LLM adapter is the default substrate: inert, network-free, safe in
# tests and safe to leave in production until a real adapter is configured. This
# spec pins its contract conformance — it implements the LLM::Base interface and
# proposes nothing, so a Visit still records cleanly with zero claims changed.
RSpec.describe Enliterator::Adapters::LLM::Null do
  subject(:adapter) { described_class.new }

  it "is a kind of LLM::Base (shares prompt-building + Result/schema)" do
    expect(adapter).to be_a(Enliterator::Adapters::LLM::Base)
  end

  describe "#model_id" do
    it "is the literal \"null\"" do
      expect(adapter.model_id).to eq("null")
    end
  end

  describe "#tend" do
    let(:result) do
      adapter.tend(
        text:      "anything",
        stream:    "summary",
        state:     { claims: [], recent_visits: [], facets: {} },
        neighbors: []
      )
    end

    it "returns a Base::Result responding to parsed/raw/tokens" do
      expect(result).to be_a(Enliterator::Adapters::LLM::Base::Result)
      expect(result).to respond_to(:parsed, :raw, :tokens)
    end

    it "parses to the empty-reconciliation shape: no claims, zero confidence" do
      expect(result.parsed).to eq("claims" => [], "confidence" => 0.0)
      expect(result.parsed["claims"]).to eq([])
      expect(result.parsed["confidence"]).to eq(0.0)
    end

    it "returns hashes for raw and tokens" do
      expect(result.raw).to be_a(Hash)
      expect(result.tokens).to be_a(Hash)
      expect(result.tokens).to eq({})
    end

    it "ignores its inputs and performs no network I/O" do
      # The Null adapter must never reach for a provider gem or a socket. Calling
      # it with rich context still yields the same inert result.
      rich = adapter.tend(
        text:      "a long body of text",
        stream:    "deep",
        state:     { claims: [ { key: "summary", value: "x" } ] },
        neighbors: [ "neighbor-1", "neighbor-2" ]
      )
      expect(rich.parsed).to eq("claims" => [], "confidence" => 0.0)
    end

    it "is the adapter Enliterator.llm falls back to when none is configured" do
      expect(Enliterator.llm).to be_a(described_class)
    end
  end
end
