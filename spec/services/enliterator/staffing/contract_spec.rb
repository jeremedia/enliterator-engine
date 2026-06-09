# frozen_string_literal: true

require "rails_helper"

# v0.3 §1 — the facet output contract on the org chart.
#
# `facet(name, tier:, keys:)` is the contract-bearing sibling of `assign`: it
# sets the tier exactly as #assign does AND records the controlled key vocabulary
# the model may assert on that facet. `assign` (no keys) stays unconstrained —
# nil from terms_for/allowed_terms — preserving v0.2 open-key behavior.
RSpec.describe Enliterator::Staffing::Policy, "facet output contracts" do
  let(:policy) do
    described_class.new do
      # Contract-bearing facet: tier + controlled vocabulary.
      facet :metadata, tier: "quality", terms: {
        author: "Who authored the work.",
        date:   "When the work was created."
      }
      # Plain assignment: tier only, no contract (unconstrained).
      assign :summary, tier: "cheap"
      ladder ["cheap", "quality"]
    end
  end

  describe "#facet sets the tier (like #assign)" do
    it "resolves the facet's tier via tier_for" do
      expect(policy.tier_for(:metadata)).to eq("quality")
      expect(policy.tier_for("metadata")).to eq("quality")
    end

    it "feeds the facet tier into the ladder/validation machinery" do
      # The facet's tier participates exactly like an assigned tier: it appears
      # among referenced_tiers (so validate! would catch a typo'd alias).
      expect(policy.referenced_tiers).to include("quality")
    end
  end

  describe "#facet sets the contract (terms_for / allowed_terms)" do
    it "terms_for returns the {key => description} contract as strings" do
      expect(policy.terms_for(:metadata)).to eq(
        "author" => "Who authored the work.",
        "date"   => "When the work was created."
      )
    end

    it "accepts a symbol or a string facet name" do
      expect(policy.terms_for("metadata")).to eq(policy.terms_for(:metadata))
    end

    it "allowed_terms returns the controlled vocabulary as a [String]" do
      expect(policy.allowed_terms(:metadata)).to contain_exactly("author", "date")
      expect(policy.allowed_terms(:metadata)).to all(be_a(String))
    end
  end

  describe "an #assign facet (no keys) is unconstrained" do
    it "terms_for is nil (not {}) — distinct from an empty contract" do
      expect(policy.terms_for(:summary)).to be_nil
    end

    it "allowed_terms is nil — signaling 'no contract', not an empty allow-list" do
      expect(policy.allowed_terms(:summary)).to be_nil
    end
  end

  describe "an undeclared facet is unconstrained" do
    it "terms_for / allowed_terms are nil for a facet never declared" do
      expect(policy.terms_for(:never_declared)).to be_nil
      expect(policy.allowed_terms(:never_declared)).to be_nil
    end
  end

  describe "the default policy carries no contracts (back-compat)" do
    it "has nil contracts for any facet" do
      default = described_class.default("cheap")
      expect(default.terms_for(:summary)).to be_nil
      expect(default.allowed_terms(:summary)).to be_nil
    end
  end
end
