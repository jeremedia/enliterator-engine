# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Widget do
  it "renders provenance as a chain: claim → visit (tier/model/at) → audits" do
    result = { claim: { key: "contribution", value: "Argues X" },
               visit: { tier: "bedrock-sonnet", model: "stub", at: "2026-06-12" },
               audits: [ { source: "examiner", verdict: "supported", rationale: "the source says so" } ] }
    html = described_class.render("provenance", result)
    expect(html).to include("contribution")
    expect(html).to include("bedrock-sonnet")
    expect(html).to include("examiner")
    expect(html).to include("supported")
  end

  it "renders accuracy as a per-facet/tier table" do
    result = { by_facet_and_tier: [ { facet: "authorship", tier: "cheap", audited: 20, supported: 19 } ],
               anchor_agreement: { rate: 0.95 } }
    html = described_class.render("accuracy", result)
    expect(html).to include("authorship")
    expect(html).to include("19")
    expect(html).to include("95").or include("0.95")
  end

  it "renders trajectory as ordered steps with per-step tier and ops" do
    result = { facet: "significance", steps: [
      { at: "2026-06-10", tier: "quality", ops: { "added" => 2, "updated" => 1 } },
      { at: "2026-06-12", tier: "bedrock-sonnet", ops: { "updated" => 3 } }
    ] }
    html = described_class.render("trajectory", result)
    expect(html).to include("significance")
    expect(html.scan("enl-step").size).to be >= 2
  end

  it "escapes untrusted values in these renderers (no injection)" do
    html = described_class.render("provenance",
      { claim: { key: "k", value: "<img src=x onerror=alert(1)>" }, visit: {}, audits: [] })
    expect(html).to include("&lt;img")
    expect(html).not_to include("<img src=x")
  end

  it "escapes untrusted values in trajectory ops and accuracy cells" do
    traj = described_class.render("trajectory",
      { facet: "f", steps: [ { at: "t", tier: "x", ops: { "<b>added</b>" => "<i>2</i>" } } ] })
    expect(traj).to include("&lt;b&gt;added&lt;/b&gt;")
    expect(traj).not_to include("<b>added</b>")
    acc = described_class.render("accuracy",
      { by_facet_and_tier: [ { facet: "<script>x</script>", tier: "t", audited: 1, supported: 1 } ] })
    expect(acc).to include("&lt;script&gt;")
    expect(acc).not_to include("<script>x")
  end
end
