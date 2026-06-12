# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Widget do
  it "renders search results as a card list (label, type, excerpt, counts)" do
    result = { results: [ { label: "A", type: "DocMetum", id: "7", excerpt: "about detention",
                            claim_count: 12, visit_count: 3 } ] }
    html = described_class.render("search", result)
    expect(html).to include("A")
    expect(html).to include("about detention")
    expect(html).to include("12")
  end

  it "renders quote with the located passage and a not-located fallback flag" do
    located = described_class.render("quote", { located: true, passage: "the tabulation showed" })
    expect(located).to include("the tabulation showed")
    lost = described_class.render("quote", { located: false, passage: "(head of source)" })
    expect(lost).to include("not located").or include("could not locate")
    expect(lost).to include("(head of source)")
  end

  it "renders connections as a typed-edge list and labels a degraded/empty neighbor set" do
    result = { edges: [ { key: "cited_works", target: "Hoffman", weight: 1 } ],
               neighbors: [], neighbors_state: "no_embedding" }
    html = described_class.render("connections", result)
    expect(html).to include("cited_works")
    expect(html).to include("Hoffman")
    expect(html).to include("no embedding").or include("not embedded")  # degraded label, not silent empty
  end

  it "escapes untrusted values in these renderers (no injection)" do
    html = described_class.render("search", { results: [ { label: "<script>x</script>", excerpt: "e" } ] })
    expect(html).to include("&lt;script&gt;")
    expect(html).not_to include("<script>x")
  end
end
