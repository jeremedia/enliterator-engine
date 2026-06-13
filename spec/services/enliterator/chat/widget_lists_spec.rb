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

  # v0.29 citations: the widgets expose record identity on data attributes so the
  # client can build the sources rail + inline chips. Additive (the visible render
  # is unchanged) and every value escaped (a data attribute is an XSS surface too).
  describe "record-identity data attributes (citations)" do
    it "stamps search result cards with escaped data-enl-type/id/label/entry" do
      html = described_class.render("search", { results: [
        { type: "DocMetum", id: "7", label: "A thesis", excerpt: "x",
          entry: "/enliterator/status/DocMetum/7" } ] })
      expect(html).to include('data-enl-type="DocMetum"')
      expect(html).to include('data-enl-id="7"')
      expect(html).to include('data-enl-label="A thesis"')
      expect(html).to include('data-enl-entry="/enliterator/status/DocMetum/7"')
    end

    it "stamps subject_search result cards with the same data attributes" do
      html = described_class.render("subject_search", { records: nil, results: [
        { type: "CrsReport", id: "12", label: "A report", entry: "/enliterator/status/CrsReport/12" } ] })
      expect(html).to include('data-enl-type="CrsReport"')
      expect(html).to include('data-enl-id="12"')
    end

    it "stamps the record_entry root with escaped data-enl attributes" do
      html = described_class.render("record_entry",
        { type: "DocMetum", id: "9", label: "Title", entry: "/enliterator/status/DocMetum/9" })
      expect(html).to include('data-enl-type="DocMetum"')
      expect(html).to include('data-enl-id="9"')
      expect(html).to include('data-enl-label="Title"')
      expect(html).to include('data-enl-entry="/enliterator/status/DocMetum/9"')
    end

    it "escapes a quote/script payload in the data attributes (no attribute break-out)" do
      evil = { results: [ { type: "DocMetum", id: '"><img src=x onerror=alert(1)>',
                            label: '<script>alert(1)</script>',
                            entry: '"/x' } ] }
      html = described_class.render("search", evil)
      # the raw payload must NEVER appear unescaped inside the attribute
      expect(html).not_to include('id="">')
      expect(html).not_to include("<img src=x onerror")
      expect(html).not_to include("<script>alert(1)")
      # the escaped forms are present (quotes → &quot;, < → &lt;)
      expect(html).to include("&quot;")
      expect(html).to include("&lt;script&gt;")
    end

    it "emits NO data-enl attributes when the result has no id (the client gate stays closed)" do
      html = described_class.render("search", { results: [ { label: "no id", excerpt: "x" } ] })
      expect(html).not_to include("data-enl-id")
      expect(html).not_to include("data-enl-type")
    end
  end
end
