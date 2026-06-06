# frozen_string_literal: true

require "rails_helper"

# The engine's local token ledger. Pure ActiveRecord read over the immutable
# Visit history — groups Visit.tokens by stream and tier. No gateway, no network.
RSpec.describe Enliterator::Spend do
  let(:widget) { Widget.create!(title: "Acme", body: "ledger fodder") }

  def visit!(stream:, tier:, input:, output:)
    widget.enliterator_visits.create!(
      stream:  stream,
      tier:    tier,
      status:  "succeeded",
      applied: true,
      tokens:  { "input" => input, "output" => output, "total" => input + output }
    )
  end

  describe ".by_stream" do
    before do
      visit!(stream: "summary", tier: "cheap",   input: 1000, output: 200)
      visit!(stream: "summary", tier: "quality", input: 200,  output: 100)
      visit!(stream: "critique", tier: "quality", input: 500, output: 50)
    end

    it "groups token usage by stream" do
      result = described_class.by_stream

      expect(result.keys).to match_array(%w[summary critique])
      expect(result["summary"][:tokens]).to eq(
        "input" => 1200, "output" => 300, "total" => 1500
      )
      expect(result["critique"][:tokens]).to eq(
        "input" => 500, "output" => 50, "total" => 550
      )
    end

    it "breaks each stream down by tier" do
      result = described_class.by_stream

      by_tier = result["summary"][:by_tier]
      expect(by_tier.keys).to match_array(%w[cheap quality])
      expect(by_tier["cheap"]).to eq("input" => 1000, "output" => 200, "total" => 1200)
      expect(by_tier["quality"]).to eq("input" => 200, "output" => 100, "total" => 300)
    end

    it "filters to a single stream when asked" do
      result = described_class.by_stream(stream: "critique")
      expect(result.keys).to eq(%w[critique])
    end

    it "buckets tier-less visits under 'unknown' (no silent drop)" do
      visit!(stream: "summary", tier: nil, input: 10, output: 5)
      result = described_class.by_stream(stream: "summary")
      expect(result["summary"][:by_tier]).to have_key("unknown")
      expect(result["summary"][:by_tier]["unknown"]).to eq(
        "input" => 10, "output" => 5, "total" => 15
      )
    end

    it "adds a cost_usd estimate when a price map is supplied" do
      result = described_class.by_stream(
        stream:    "summary",
        price_map: {
          "cheap"   => { input: 0.0,     output: 0.0 },
          "quality" => { input: 0.00125, output: 0.01 }
        }
      )
      # quality only: (200/1000)*0.00125 + (100/1000)*0.01 = 0.00025 + 0.001 = 0.00125
      expect(result["summary"][:cost_usd]).to be_within(1e-9).of(0.00125)
    end
  end
end
