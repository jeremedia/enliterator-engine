# frozen_string_literal: true
require "rails_helper"

# v0.28 — the widget renderers: pure functions of a tool's JSON result → self-
# contained HTML. record_entry renders the finding-aid card.
RSpec.describe Enliterator::Chat::Widget do
  it "renders record_entry as a card: label, claims grouped by facet, provenance fields" do
    result = {
      label: "A Thesis on Detention",
      claims_by_facet: { "significance" => [
        { id: 5, key: "contribution", value: "Argues X", confidence: 0.8, tier: "bedrock-sonnet",
          status: "live", audit_verdict: "supported" }
      ] },
      entry: "/enliterator/status/DocMetum/7"
    }
    html = described_class.render("record_entry", result)
    expect(html).to include("A Thesis on Detention")
    expect(html).to include("significance")
    expect(html).to include("contribution")
    expect(html).to include("Argues X")
    expect(html).to include("supported")           # the audit verdict shows
    expect(html).not_to include("<script")          # self-contained, inert
  end

  it "HTML-escapes claim values (no injection through tool data)" do
    result = { label: "T", claims_by_facet: { "f" => [ { key: "k", value: "<img src=x onerror=alert(1)>" } ] } }
    html = described_class.render("record_entry", result)
    expect(html).to include("&lt;img")
    expect(html).not_to include("<img src=x")
  end

  it "never raises on an unknown tool — falls back to a labeled JSON block" do
    html = described_class.render("no_such_tool", { a: 1 })
    expect(html).to include("no_such_tool")
    expect(html).to include("&quot;a&quot;").or include("\"a\"")
  end

  it "HTML-escapes tool data in the fallback JSON block" do
    html = described_class.render("no_such_tool", { "<script>" => "alert(1)" })
    expect(html).to include("&lt;script&gt;")
    expect(html).not_to include("<script>")
  end
end
