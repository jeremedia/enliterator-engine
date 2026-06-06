# frozen_string_literal: true

require "rails_helper"

# v0.3 §1 — the stream output contract on the org chart.
#
# `stream(name, tier:, keys:)` is the contract-bearing sibling of `assign`: it
# sets the tier exactly as #assign does AND records the controlled key vocabulary
# the model may assert on that stream. `assign` (no keys) stays unconstrained —
# nil from keys_for/allowed_keys — preserving v0.2 open-key behavior.
RSpec.describe Enliterator::Staffing::Policy, "stream output contracts" do
  let(:policy) do
    described_class.new do
      # Contract-bearing stream: tier + controlled vocabulary.
      stream :metadata, tier: "quality", keys: {
        author: "Who authored the work.",
        date:   "When the work was created."
      }
      # Plain assignment: tier only, no contract (unconstrained).
      assign :summary, tier: "cheap"
      ladder ["cheap", "quality"]
    end
  end

  describe "#stream sets the tier (like #assign)" do
    it "resolves the stream's tier via tier_for" do
      expect(policy.tier_for(:metadata)).to eq("quality")
      expect(policy.tier_for("metadata")).to eq("quality")
    end

    it "feeds the stream tier into the ladder/validation machinery" do
      # The stream's tier participates exactly like an assigned tier: it appears
      # among referenced_tiers (so validate! would catch a typo'd alias).
      expect(policy.referenced_tiers).to include("quality")
    end
  end

  describe "#stream sets the contract (keys_for / allowed_keys)" do
    it "keys_for returns the {key => description} contract as strings" do
      expect(policy.keys_for(:metadata)).to eq(
        "author" => "Who authored the work.",
        "date"   => "When the work was created."
      )
    end

    it "accepts a symbol or a string stream name" do
      expect(policy.keys_for("metadata")).to eq(policy.keys_for(:metadata))
    end

    it "allowed_keys returns the controlled vocabulary as a [String]" do
      expect(policy.allowed_keys(:metadata)).to contain_exactly("author", "date")
      expect(policy.allowed_keys(:metadata)).to all(be_a(String))
    end
  end

  describe "an #assign stream (no keys) is unconstrained" do
    it "keys_for is nil (not {}) — distinct from an empty contract" do
      expect(policy.keys_for(:summary)).to be_nil
    end

    it "allowed_keys is nil — signaling 'no contract', not an empty allow-list" do
      expect(policy.allowed_keys(:summary)).to be_nil
    end
  end

  describe "an undeclared stream is unconstrained" do
    it "keys_for / allowed_keys are nil for a stream never declared" do
      expect(policy.keys_for(:never_declared)).to be_nil
      expect(policy.allowed_keys(:never_declared)).to be_nil
    end
  end

  describe "the default policy carries no contracts (back-compat)" do
    it "has nil contracts for any stream" do
      default = described_class.default("cheap")
      expect(default.keys_for(:summary)).to be_nil
      expect(default.allowed_keys(:summary)).to be_nil
    end
  end
end
