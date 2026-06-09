# frozen_string_literal: true

require "rails_helper"

# v0.15 — cycle provenance. A visit caused by a heartbeat carries the cycle
# (heartbeat_id) and WHY it was scheduled (reason) on every row the Visitor
# creates, on both paths. Direct tends keep NULL/NULL — byte-identical.
RSpec.describe "Enliterator::Tending::Visitor heartbeat provenance (v0.15)" do
  let(:widget)   { Widget.create!(title: "T", body: "b") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }
  let(:beat) do
    Enliterator::Heartbeat.create!(started_at: Time.current, mode: "sync", budget_tokens: 1000)
  end

  class ProvStub
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    def model_id = "model-cheap"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {}, tokens: {})
    end
  end

  it "stamps heartbeat + reason on the staffing-path visit" do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(ProvStub.new)

    visit = Enliterator::Tending::Visitor.new(
      widget, facet: "summary", embedder: embedder, heartbeat: beat, reason: "frontier"
    ).call

    expect(visit.heartbeat).to eq(beat)
    expect(visit.reason).to eq("frontier")
    expect(beat.visits).to include(visit)
  end

  it "stamps the back-compat (injected llm) path too" do
    visit = Enliterator::Tending::Visitor.new(
      widget, facet: "summary", llm: ProvStub.new, embedder: embedder,
      heartbeat: beat, reason: "vocabulary"
    ).call

    expect(visit.heartbeat_id).to eq(beat.id)
    expect(visit.reason).to eq("vocabulary")
  end

  it "a direct tend (no heartbeat) stays NULL/NULL — byte-identical to v0.14" do
    visit = Enliterator::Tending::Visitor.new(
      widget, facet: "summary", llm: ProvStub.new, embedder: embedder
    ).call

    expect(visit.heartbeat_id).to be_nil
    expect(visit.reason).to be_nil
  end
end
