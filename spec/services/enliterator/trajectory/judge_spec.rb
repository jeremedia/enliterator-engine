# frozen_string_literal: true

require "rails_helper"

# v0.14 — the blind pairwise judge. Order is randomized per call; the verdict is
# de-blinded locally; the Null adapter degrades to nil (never raises).
RSpec.describe Enliterator::Trajectory::Judge do
  let(:widget) { Widget.create!(title: "T", body: "document text about FOIA") }
  let(:t1) { 3.hours.ago }
  let(:t2) { 1.hour.ago }

  # Two visits with an UPDATE chain between them.
  before do
    v1 = widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true,
                                           tier: "cheap", created_at: t1, updated_at: t1)
    old = widget.enliterator_claims.create!(key: "summary", value: "shallow first take",
                                            visit: v1, status: "draft", created_at: t1, updated_at: t1)
    v2 = widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true,
                                           tier: "cheap", created_at: t2, updated_at: t2)
    fresh = widget.enliterator_claims.create!(key: "summary", value: "a deeper synthesis with citations",
                                              visit: v2, status: "draft", created_at: t2, updated_at: t2)
    old.supersede!(fresh)
  end

  let(:early) { widget.enliterator_visits.order(:created_at).first }
  let(:late)  { widget.enliterator_visits.order(:created_at).last }

  # A decide stub that always prefers the candidate containing "deeper" —
  # i.e. the LATER state, whichever blind label it got. Records the prompt.
  class PreferDeeperStub
    attr_reader :last_messages
    def model_id = "stub-quality"
    def decide(messages:, schema:, tool_name:, tags: [])
      @last_messages = messages
      user = messages.last[:content]
      a_block = user[/CANDIDATE A.*?(?=CANDIDATE B)/m]
      deeper_label = a_block.include?("deeper") ? "A" : "B"
      { "winner" => deeper_label, "richer" => deeper_label, "more_accurate" => "tie",
        "rationale" => "more synthesis", "confidence" => 0.9 }
    end
  end

  it "de-blinds correctly REGARDLESS of the random assignment (both orders exercised)" do
    [ Random.new(1), Random.new(2), Random.new(3), Random.new(4) ].each do |rng|
      verdict = described_class.new(llm: PreferDeeperStub.new, rng: rng)
                  .judge!(widget, facet: "summary", early: early, late: late)
      expect(verdict[:later_wins]).to be(true), "seed produced wrong de-blinding"
      expect(verdict[:richer]).to eq(:later)
      expect(verdict[:more_accurate]).to eq(:tie)
    end
  end

  it "never leaks order language into the prompt (no before/after/earlier/later/newer)" do
    stub = PreferDeeperStub.new
    described_class.new(llm: stub).judge!(widget, facet: "summary", early: early, late: late)
    text = stub.last_messages.map { |m| m[:content] }.join(" ")
    expect(text).not_to match(/\b(before|after|earlier|later|newer|older|previous|original)\b/i)
  end

  it "maps a tie verdict to later_wins: nil" do
    tie_stub = Class.new do
      def model_id = "stub"
      def decide(messages:, schema:, tool_name:, tags: [])
        { "winner" => "tie", "richer" => "tie", "more_accurate" => "tie", "rationale" => "same", "confidence" => 0.5 }
      end
    end.new
    verdict = described_class.new(llm: tie_stub).judge!(widget, facet: "summary", early: early, late: late)
    expect(verdict[:later_wins]).to be_nil
    expect(verdict[:winner]).to eq(:tie)
  end

  it "degrades to nil on the Null adapter (no gateway) without raising" do
    verdict = nil
    expect {
      verdict = described_class.new(llm: Enliterator::Adapters::LLM::Null.new)
                  .judge!(widget, facet: "summary", early: early, late: late)
    }.not_to raise_error
    expect(verdict).to be_nil
  end
end
