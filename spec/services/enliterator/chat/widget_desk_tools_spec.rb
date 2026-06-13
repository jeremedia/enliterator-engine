# frozen_string_literal: true
require "rails_helper"

# v0.29: the Reference Desk's orientation widgets — overview / browse_subjects /
# vocabulary / recent_activity. Same contract as widget_lists_spec: pure
# functions, every interpolated value escaped, a visible state on the degraded
# path, and never the model-facing `next:` block.
RSpec.describe Enliterator::Chat::Widget do
  # ---- collection_overview -------------------------------------------------
  describe "collection_overview" do
    let(:result) do
      {
        context: "root",
        stats: { enliterated: 1327, corpus: 37455, live_claims: 9001, vocabulary_keys: 42 },
        types: { "DocMetum" => 1200, "CrsReport" => 127 },
        contexts: [ { key: "chds-theses", name: "CHDS Theses", parent: nil, members: 1327 } ],
        facets: [ { facet: "significance", tier: "quality", tended_count: 88, terms: %w[impact reach] },
                  { facet: "summary", tier: "cheap", tended_count: 1200, terms: [] } ],
        condition: { surveyed: 1300, total: 1327, untendable: 4, residue_count: 12,
                     piles: [ { signature: "rung4:never_understood", count: 12, band: "0.0" } ] },
        accuracy: [ { facet: "significance", tier: "quality", audited: 30,
                      supported_rate: 0.933, contradicted: 1 } ],
        next: { vocabulary: "term meanings per facet" }
      }
    end

    it "renders the overview widget with the shared stat-strip and facet chips" do
      html = described_class.render("collection_overview", result)
      expect(html).to include("enl-widget enl-widget--overview")
      expect(html).to include("stats-strip")
      expect(html).to include("stats-grid")
      expect(html).to include("stat-cell")
      expect(html).to include("stat-num")
      # the four headline numbers
      expect(html).to include("1327")   # enliterated
      expect(html).to include("37455")  # corpus
      expect(html).to include("9001")   # live claims
      expect(html).to include("42")     # vocabulary keys
      # facet chips: facet · tended_count
      expect(html).to include("facet-chip")
      expect(html).to include("significance")
      expect(html).to include("88")
    end

    it "renders the context tree and accuracy table inside collapsed details" do
      html = described_class.render("collection_overview", result)
      expect(html).to include("<details")
      expect(html).to include("chds-theses")          # context tree row
      expect(html).to include("enl-accuracy")          # reused accuracy table shape
      expect(html).to include("0.933")                 # supported_rate
      # details must NOT be open by default (collapsed)
      expect(html).not_to include("<details open")
    end

    it "does not render the model-facing next: block" do
      html = described_class.render("collection_overview", result)
      expect(html).not_to include("term meanings per facet")
    end

    it "escapes untrusted values (no injection through facet/context names)" do
      evil = { stats: { enliterated: 1 },
               contexts: [ { key: '"><img src=x onerror=alert(1)>', name: "n", members: 1 } ],
               facets: [ { facet: "<script>alert(1)</script>", tended_count: 1 } ],
               accuracy: [ { facet: "<b>a</b>", tier: "t", audited: 1, supported_rate: 1.0, contradicted: 0 } ] }
      html = described_class.render("collection_overview", evil)
      expect(html).not_to include("<script>alert(1)")
      expect(html).not_to include("<img src=x onerror")
      expect(html).not_to include("<b>a</b>")
      expect(html).to include("&lt;script&gt;")
    end

    it "renders without raising on a near-empty result" do
      html = described_class.render("collection_overview", { context: "root" })
      expect(html).to include("enl-widget--overview")
    end
  end

  # ---- browse_subjects -----------------------------------------------------
  describe "browse_subjects" do
    let(:result) do
      {
        context: "root",
        headings: [
          { key: "index_terms",
            values: (1..12).map { |i| [ "term#{i}", 13 - i ] } },
          { key: "subjects", approximate: true,
            values: [ [ "Detention", 40 ], [ "Borders", 22 ] ] }
        ],
        next: { subject_search: "the records behind any heading" }
      }
    end

    it "renders the headings widget with a key and value chips" do
      html = described_class.render("browse_subjects", result)
      expect(html).to include("enl-widget enl-widget--headings")
      expect(html).to include("enl-headings__key")
      expect(html).to include("index_terms")
      expect(html).to include("enl-headings__vals")
      expect(html).to include("enl-headval")
      expect(html).to include("Detention")
      expect(html).to include("40")
    end

    it "shows the approximate-counts note when a heading is approximate" do
      html = described_class.render("browse_subjects", result)
      expect(html).to include("approximate")
    end

    it "shows up to ~8 values inline and the rest behind a show-all details" do
      html = described_class.render("browse_subjects", result)
      expect(html).to include("<details")     # the index_terms heading has 12 values
      expect(html).to include("term1")
      expect(html).to include("term12")        # still present, inside the details
    end

    it "does not render the model-facing next: block" do
      html = described_class.render("browse_subjects", result)
      expect(html).not_to include("the records behind any heading")
    end

    it "escapes untrusted heading keys and terms" do
      html = described_class.render("browse_subjects", {
        headings: [ { key: "<script>k</script>", values: [ [ '"><img src=x onerror=alert(1)>', 3 ] ] } ]
      })
      expect(html).not_to include("<script>k")
      expect(html).not_to include("<img src=x onerror")
      expect(html).to include("&lt;script&gt;")
    end

    it "renders a visible empty state with no headings" do
      html = described_class.render("browse_subjects", { context: "root", headings: [] })
      expect(html).to include("enl-widget--headings")
      expect(html).to match(/no subject headings|no headings/i)
    end
  end

  # ---- vocabulary ----------------------------------------------------------
  describe "vocabulary" do
    let(:result) do
      {
        context: "root",
        facets: [
          { facet: "significance", declared_in: "root", tier: "quality",
            required: [ "impact" ], scheduled: true,
            terms: { "impact" => "why it matters", "reach" => "how far it spread" } },
          { facet: "freeform", declared_in: "root", tier: "cheap",
            required: [], scheduled: false }   # terms key omitted (nil → open facet)
        ],
        next: { propose_term: "file a vocabulary suggestion" }
      }
    end

    it "renders the vocab widget with facet name, tier chip and scheduling" do
      html = described_class.render("vocabulary", result)
      expect(html).to include("enl-widget enl-widget--vocab")
      expect(html).to include("enl-vocab__facet")
      expect(html).to include("enl-vocab__name")
      expect(html).to include("significance")
      expect(html).to include("chip tier")
      expect(html).to include("quality")
      expect(html).to match(/scheduled|unscheduled/)
    end

    it "renders term: meaning rows and marks required terms" do
      html = described_class.render("vocabulary", result)
      expect(html).to include("enl-vocab__term")
      expect(html).to include("impact")
      expect(html).to include("why it matters")
      expect(html).to include("enl-vocab__term--req")   # impact is required
    end

    it "renders an open-facet line when terms is nil/absent (rule 3, no blank)" do
      html = described_class.render("vocabulary", result)
      expect(html).to include("open facet")
      expect(html).to include("unconstrained")
    end

    it "renders an open-facet line when terms is explicitly nil" do
      html = described_class.render("vocabulary", {
        facets: [ { facet: "f", tier: "cheap", terms: nil } ]
      })
      expect(html).to include("open facet")
    end

    it "does not render the model-facing next: block" do
      html = described_class.render("vocabulary", result)
      expect(html).not_to include("file a vocabulary suggestion")
    end

    it "escapes untrusted facet names, terms, and meanings" do
      html = described_class.render("vocabulary", {
        facets: [ { facet: "<script>f</script>", tier: "<b>t</b>",
                    terms: { '"><img src=x onerror=alert(1)>' => "<i>m</i>" } } ]
      })
      expect(html).not_to include("<script>f")
      expect(html).not_to include("<img src=x onerror")
      expect(html).not_to include("<i>m</i>")
      expect(html).to include("&lt;script&gt;")
    end
  end

  # ---- recent_activity -----------------------------------------------------
  describe "recent_activity" do
    let(:result) do
      {
        window: { since: "2026-06-12 17:00", hours: 12.0 },
        headline: "2 heartbeats · 53 visits (1 failed) · 173,000 tokens",
        visits: { total: 53, by_facet: { "significance" => { "succeeded" => 52 } },
                  by_tier: { "quality" => 40, "cheap" => 13 },
                  by_reason: { "frontier" => 53 }, tokens: 173_000 },
        failures: { count: 1,
                    sample: [ { at: "2026-06-12 18:01", facet: "significance", tier: "quality",
                                record: "DocMetum/77", error: "gateway timeout after 180s" } ],
                    truncated: false },
        readings: { records: 1, parts_read: 26, parts_failed: 0, syntheses: 3, tokens: 90_000 },
        governance: { suggestions: { "open" => 3 }, term_motion: {}, audits: { "examiner" => { "supported" => 5 } } },
        embeddings: { written: 53 },
        next: { collection_overview: "the collection's current state" }
      }
    end

    it "renders the activity widget with the headline as a lead line" do
      html = described_class.render("recent_activity", result)
      expect(html).to include("enl-widget enl-widget--activity")
      expect(html).to include("2 heartbeats")
      expect(html).to include("173,000 tokens")
    end

    it "renders visits-by-tier and failures inside collapsed details" do
      html = described_class.render("recent_activity", result)
      expect(html).to include("<details")
      expect(html).not_to include("<details open")
      expect(html).to include("quality")     # a tier
      expect(html).to include("40")          # its count
    end

    it "makes each failure's error text visible" do
      html = described_class.render("recent_activity", result)
      expect(html).to include("gateway timeout after 180s")
      expect(html).to include("DocMetum/77")
    end

    it "does not render the model-facing next: block" do
      html = described_class.render("recent_activity", result)
      expect(html).not_to include("the collection's current state")
    end

    it "renders an honest empty state when the window was quiet" do
      html = described_class.render("recent_activity", {
        window: { since: "2026-06-12 17:00", hours: 12.0 },
        headline: "0 heartbeats · 0 visits · 0 tokens",
        visits: { total: 0, by_facet: {}, by_tier: {}, by_reason: {}, tokens: 0 },
        failures: { count: 0, sample: [], truncated: false }
      })
      html2 = described_class.render("recent_activity", { window: { hours: 12 } })
      expect(html).to match(/no activity|nothing/i)
      expect(html2).to match(/no activity|nothing/i)
    end

    it "escapes untrusted error text" do
      html = described_class.render("recent_activity", {
        headline: "1 visit (1 failed)",
        visits: { total: 1 },
        failures: { count: 1,
                    sample: [ { facet: "f", record: "X/1",
                                error: '<script>alert(1)</script>' } ], truncated: false }
      })
      expect(html).not_to include("<script>alert(1)")
      expect(html).to include("&lt;script&gt;")
    end
  end

  # ---- fallback (now collapsed) --------------------------------------------
  describe "the raw fallback" do
    it "wraps the raw JSON in a collapsed details and keeps the raw classes" do
      html = described_class.render("some_unknown_tool", { a: 1, b: "two" })
      expect(html).to include("enl-widget enl-widget--raw")
      expect(html).to include("enl-widget__json")
      expect(html).to include("<details")
      expect(html).not_to include("<details open")
      expect(html).to include("some_unknown_tool")
      expect(html).to include("two")
    end

    it "escapes untrusted content in the raw fallback" do
      html = described_class.render("x", { evil: "<script>alert(1)</script>" })
      expect(html).not_to include("<script>alert(1)")
      expect(html).to include("&lt;script&gt;")
    end
  end
end
