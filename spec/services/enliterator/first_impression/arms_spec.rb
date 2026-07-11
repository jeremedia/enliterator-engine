# frozen_string_literal: true

require "rails_helper"

# v0.58 — the first-impression diagnostic's reading conditions. Pure context
# builders: the non-fulltext arms share the surrogate (the confound control);
# only `manual` adds the enliteration, only `map` adds bibliographic access points.
RSpec.describe Enliterator::FirstImpression::Arms do
  Claim = Struct.new(:key, :value, :confidence, :audit_verdict) unless defined?(Claim)
  let(:record) do
    double("Widget", enliterator_text: "This thesis studies arson threats.", title: "Arson Threats")
  end
  let(:claims) do
    [
      Claim.new("authored_by", "Robert A. Neale", 1.0, "supported"),
      Claim.new("keywords", %w[Arson Physical\ Security], 0.9, nil),
      Claim.new("key_findings", "The standard is deficient for arson protection.", 0.93, "supported")
    ]
  end

  describe ".build" do
    it "returns the host-generic core (3 arms) with no full_text" do
      arms = described_class.build(record, claims: claims)
      expect(arms.keys).to contain_exactly("no_map", "map", "manual")
    end

    it "adds the fulltext arm only when the host supplies a full source" do
      arms = described_class.build(record, claims: claims, full_text: "full body text " * 50)
      expect(arms.keys).to include("fulltext")
      expect(arms["fulltext"]).to include("full body text")
    end

    it "treats a blank full_text as no fulltext arm" do
      expect(described_class.build(record, claims: claims, full_text: "  ").keys)
        .to contain_exactly("no_map", "map", "manual")
    end
  end

  it "puts the deep finding in manual but NOT in no_map or map (the confound control)" do
    arms = described_class.build(record, claims: claims)
    finding = "deficient for arson protection"
    expect(arms["manual"]).to include(finding)
    expect(arms["no_map"]).not_to include(finding)
    expect(arms["map"]).not_to include(finding)
  end

  it "all non-fulltext arms carry the same surrogate text" do
    arms = described_class.build(record, claims: claims)
    %w[no_map map manual].each { |a| expect(arms[a]).to include("studies arson threats") }
  end

  it "the map arm carries the title + bibliographic claims, not the deep findings" do
    map = described_class.build(record, claims: claims)["map"]
    expect(map).to include("Title: Arson Threats").and include("Robert A. Neale")
    expect(map).not_to include("deficient")
  end

  it "the manual enliteration renders claims with confidence and audit verdict" do
    manual = described_class.build(record, claims: claims)["manual"]
    expect(manual).to include("key_findings:").and include("audit: supported").and include("confidence 0.93")
  end
end
