# frozen_string_literal: true

require "rails_helper"

# The org chart, in isolation. No Visitor, no gateway — just the declarative
# Policy and its query API. Proves the boot-time guard (validate!), role→tier
# resolution, the escalation ladder, the verify floor, and constraint clamping
# (on-prem-only). Also proves the safe default policy.
RSpec.describe Enliterator::Staffing::Policy do
  # A minimal tendable double for allowed_tiers — only needs to answer (or not)
  # the on-prem host hook. A bare Object never escalates off-prem clamping.
  let(:off_prem_record)  { Object.new }
  let(:on_prem_record) do
    Object.new.tap do |o|
      def o.enliterator_on_prem_only? = true
    end
  end

  let(:policy) do
    described_class.new do
      assign :summary, tier: "cheap"
      assign :critique, tier: "quality"
      embedding_tier "embed"
      ladder ["cheap", "quality"]
      verify_floor "quality"
      on_prem_tiers ["cheap"]
    end
  end

  describe "#validate!" do
    it "passes when every referenced alias exists in the gateway's advertised set" do
      expect {
        policy.validate!(%w[cheap quality embed instant])
      }.not_to raise_error
    end

    it "raises ConfigurationError listing the unknown aliases" do
      expect {
        policy.validate!(%w[cheap embed]) # missing "quality"
      }.to raise_error(Enliterator::ConfigurationError, /unknown LiteLLM aliases/i)

      expect {
        policy.validate!(%w[cheap embed])
      }.to raise_error(Enliterator::ConfigurationError, /quality/)
    end

    it "returns self on success (chainable)" do
      expect(policy.validate!(%w[cheap quality embed])).to be(policy)
    end
  end

  describe "#tier_for" do
    it "returns the assigned tier for a mapped stream" do
      expect(policy.tier_for("summary")).to eq("cheap")
      expect(policy.tier_for(:critique)).to eq("quality")
    end

    it "falls back to the ladder head for an unmapped stream" do
      expect(policy.tier_for("unmapped_role")).to eq("cheap")
    end
  end

  describe "#ladder_from" do
    it "returns the remaining climb at/after a tier, in ladder order" do
      expect(policy.ladder_from("cheap")).to eq(%w[cheap quality])
      expect(policy.ladder_from("quality")).to eq(%w[quality])
    end

    it "returns just [tier] for a tier not on the ladder" do
      expect(policy.ladder_from("embed")).to eq(%w[embed])
    end
  end

  describe "#may_verify?" do
    it "permits a tier at or above the verify floor" do
      expect(policy.may_verify?("quality")).to be(true)
    end

    it "forbids a tier below the verify floor" do
      expect(policy.may_verify?("cheap")).to be(false)
    end
  end

  describe "#allowed_tiers" do
    it "returns the full clamped ladder for an off-prem record" do
      expect(policy.allowed_tiers(off_prem_record, "summary")).to eq(%w[cheap quality])
    end

    it "clamps an on-prem-only record to the on-prem tiers (no off-prem escalation)" do
      expect(policy.allowed_tiers(on_prem_record, "summary")).to eq(%w[cheap])
    end
  end

  describe ".default" do
    let(:default_policy) { described_class.default("cheap") }

    it "routes every stream to the single default tier" do
      expect(default_policy.tier_for("anything")).to eq("cheap")
      expect(default_policy.tier_for("summary")).to eq("cheap")
    end

    it "has a single-element ladder and lets that tier verify" do
      expect(default_policy.ladder).to eq(%w[cheap])
      expect(default_policy.may_verify?("cheap")).to be(true)
    end
  end
end
