# frozen_string_literal: true

require "rails_helper"

# v0.26 — the MCP tools: projections over the cached services, bounded and
# self-describing; writes go ONLY through the governed loops. The flag_claim
# pins matter most: an agent flag changes NO accuracy number.
RSpec.describe "Enliterator MCP tools", type: :request do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def enliterate!(title, body: "b", **claims)
    w = Widget.create!(title: title, body: body)
    claims.each do |key, value|
      visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded",
                                           applied: true, tier: "cheap")
      w.enliterator_claims.create!(key: key.to_s, value: value, status: "draft",
                                   confidence: 0.8, visit: visit)
    end
    w.enliterator_embeddings.create!(
      kind: "primary", embedding: embedder.embed(w.enliterator_text),
      dimensions: embedder.dimensions, model: "null"
    )
    w
  end

  def call_tool(name, **args)
    Enliterator::Mcp.dispatch(name, args.transform_keys(&:to_s))
  end

  describe "collection_overview / vocabulary" do
    it "assembles the self-portrait: stats, contexts, facets, condition, accuracy" do
      ctx = Enliterator::Context.create!(key: "es", name: "ES")
      enliterate!("A", advisor: "Dr. Voss").place_in_context!(ctx)

      o = call_tool("collection_overview")
      expect(o[:stats]).to include(:enliterated, :corpus, :live_claims)
      expect(o[:contexts].map { |c| c[:key] }).to include("es")
      expect(o[:condition]).to have_key(:untendable)
      expect(o).to have_key(:accuracy)
      expect(o[:next]).to be_present
    end

    it "speaks the claim language: tiers, required terms, scheduling, term meanings" do
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :summary, tier: "cheap", terms: { summary: "An abstract." }
          ladder [ "cheap" ]
        end
      end
      v = call_tool("vocabulary", facet: "summary")
      facet = v[:facets].first
      expect(facet[:facet]).to eq("summary")
      expect(facet[:tier]).to be_present
      expect(facet).to have_key(:scheduled)
      expect { call_tool("vocabulary", facet: "nonsense") }.to raise_error(ArgumentError, /unknown facet/)
    end
  end

  describe "search / browse_subjects / subject_search" do
    it "searches by meaning with bounded, linked cards" do
      enliterate!("Alpha", body: "human trafficking and disaster response", advisor: "Dr. Voss")
      enliterate!("Beta",  body: "wildfire fuel management")

      out = call_tool("search", q: "human trafficking", limit: 1)
      expect(out[:records].size).to eq(1)
      card = out[:records].first
      expect(card[:label]).to eq("Alpha")
      expect(card[:entry]).to include("/enliterator/status/Widget/")
      expect(card[:distance]).to be_a(Numeric)
    end

    it "names a dead embedder instead of faking results" do
      dead = Class.new { def embed(_q) = nil }.new
      original = Enliterator.configuration.embedder_adapter
      Enliterator.configure { |c| c.embedder_adapter = dead }
      expect { call_tool("search", q: "x") }
        .to raise_error(/semantic search is unavailable/)
    ensure
      Enliterator.configure { |c| c.embedder_adapter = original }
    end

    it "drops an unrecognized optional type filter instead of failing the whole search" do
      # A reader model often guesses a domain-natural type ("thesis"/"theses") that is
      # NOT a tended Ruby class. The optional filter must be ignored (search unfiltered),
      # never raise and kill the search — that turned a good query into a fake outage.
      enliterate!("Gamma", body: "counter-drone detection and response", advisor: "Dr. Voss")
      out = nil
      expect { out = call_tool("search", q: "counter-drone", type: "thesis") }.not_to raise_error
      expect(out[:records].map { |c| c[:label] }).to include("Gamma")
    end

    it "headings and their click-throughs agree (the v0.24 congruence, agent-shaped)" do
      enliterate!("A", advisor: "Dr. Voss")
      enliterate!("B", advisor: "Dr. Voss")

      headings = call_tool("browse_subjects")[:headings]
      advisor  = headings.find { |h| h[:key] == "advisor" }
      term, n  = advisor[:values].first
      expect(call_tool("subject_search", key: "advisor", value: term)[:total]).to eq(n)
    end
  end

  describe "record_entry" do
    it "returns claims grouped by facet with provenance, tending rollup, and parts when deep-read" do
      w = enliterate!("Continuity", summary: "How clerks keep elections running.", advisor: "Dr. Voss")
      claim = w.enliterator_claims.find_by(key: "advisor")
      Enliterator::Audit.create!(claim: claim, source: "examiner", auditor: "t", verdict: "supported", rationale: "r")
      Enliterator::Part.refresh_for!(w, [ { heading: "Intro", text: "alpha" } ])

      entry = call_tool("record_entry", type: "Widget", id: w.id.to_s)
      expect(entry[:label]).to eq("Continuity")
      cards = entry[:claims]["summary"]
      expect(cards.map { |c| c[:key] }).to contain_exactly("summary", "advisor")
      advisor = cards.find { |c| c[:key] == "advisor" }
      expect(advisor).to include(audit_verdict: "examiner:supported", confidence: 0.8)
      expect(entry[:tending][:visits]).to eq(2)
      expect(entry[:parts].first).to include(heading: "Intro", claim_count: 0)
    end

    it "an analytical entry (Part) has an entry too" do
      w = enliterate!("Host")
      part = Enliterator::Part.refresh_for!(w, [ { heading: "Method", text: "case study" } ]).first
      entry = call_tool("record_entry", type: "Enliterator::Part", id: part.id.to_s)
      expect(entry[:label]).to eq("Method")
    end
  end

  describe "connections / trajectory" do
    it "projects the record's typed edges and semantic neighbors" do
      a = enliterate!("A", advisor: "Dr. Mara Voss")
      b = enliterate!("B", advisor: "Dr. Mara Voss")

      out = call_tool("connections", type: "Widget", id: a.id.to_s)
      advisor_edge = out[:edges].find { |e| e[:key] == "advisor" }
      expect(advisor_edge[:target]).to include(kind: "entity", label: "Dr. Mara Voss")
      expect(out[:neighbors].map { |n| n[:label] }).to include("B")
      expect(b).to be_persisted
    end

    it "narrates the compounding: per-visit ops and changes" do
      w = Widget.create!(title: "T", body: "b")
      stub = Class.new do
        Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
        def initialize = @n = 0
        def model_id = "stub"
        def tend(text:, facet:, state:, neighbors:)
          @n += 1
          op = @n == 1 ? { "key" => "summary", "op" => "ADD", "value" => "v1", "confidence" => 0.6 }
                       : { "key" => "summary", "op" => "UPDATE", "value" => "v2", "confidence" => 0.9 }
          Result.new(parsed: { "claims" => [ op ], "confidence" => 0.8 }, raw: {},
                     tokens: { "total" => 2 })
        end
      end.new
      2.times { w.tend!(facet: "summary", llm: stub) }

      out = call_tool("trajectory", type: "Widget", id: w.id.to_s, facet: "summary")
      steps = out[:facets].first[:steps]
      expect(steps.size).to eq(2)
      expect(steps.last[:changes].first).to include(key: "summary", to: "v2")
    end
  end

  describe "provenance / quote" do
    it "answers 'how do you know that?' with the full chain" do
      w = enliterate!("A", advisor: "Dr. Voss")
      claim = w.enliterator_claims.find_by(key: "advisor")
      Enliterator::Audit.create!(claim: claim, source: "examiner", auditor: "t",
                                 verdict: "supported", rationale: "title page names her")

      out = call_tool("provenance", claim_id: claim.id)
      expect(out[:claim][:key]).to eq("advisor")
      expect(out[:visit][:facet]).to eq("summary")
      expect(out[:audits].first).to include(source: "examiner", verdict: "supported")
      expect(out[:record][:entry]).to include("/enliterator/status/Widget/")
    end

    it "locates an exact quote, a token-run, and admits when it cannot" do
      body = "The county clerks of Wisconsin maintained continuity of operations through " \
             "redundant tabulation systems and statutory fallback procedures."
      w = enliterate!("Q", body: body,
                      finding: "redundant tabulation systems and statutory fallback procedures",
                      gist:    "Clerks in Wisconsin relied on tabulation redundancy and fallback statutes.",
                      alien:   "completely unrelated assertion about volcanoes")

      exact = call_tool("quote", claim_id: w.enliterator_claims.find_by(key: "finding").id)
      expect(exact[:located]).to be(true)
      expect(exact[:passage]).to include("redundant tabulation systems")

      run = call_tool("quote", claim_id: w.enliterator_claims.find_by(key: "gist").id)
      expect(run[:located]).to be(true)
      expect(run[:passage]).to include("tabulation")

      lost = call_tool("quote", claim_id: w.enliterator_claims.find_by(key: "alien").id)
      expect(lost[:located]).to be(false)
      expect(lost[:passage]).to be_present   # the honest head, labeled
    end
  end

  describe "value truncation (v0.64 — untruncated claim values)" do
    # a contribution argument longer than the 400-char record_entry card cap
    let(:long) { "The book's contribution is " + ("a genuinely novel synthesis, " * 40) }
    let(:w)    { enliterate!("Long", contribution: long) }
    let(:claim) { w.enliterator_claims.find_by(key: "contribution") }

    it "record_entry still caps at 400 by default (byte-identical), flagging truncated" do
      out = call_tool("record_entry", type: "Widget", id: w.id.to_s)
      card = out[:claims].values.flatten.find { |c| c[:key] == "contribution" }
      expect(card[:value].length).to eq(401)          # 400 + the ellipsis char
      expect(card[:value]).to end_with("…")
      expect(card[:truncated]).to be(true)
    end

    it "record_entry value_chars: 0 returns the FULL value, unflagged" do
      out = call_tool("record_entry", type: "Widget", id: w.id.to_s, value_chars: 0)
      card = out[:claims].values.flatten.find { |c| c[:key] == "contribution" }
      expect(card[:value]).to eq(long)
      expect(card[:truncated]).to be_nil
    end

    it "record_entry value_chars: N caps at N" do
      out = call_tool("record_entry", type: "Widget", id: w.id.to_s, value_chars: 50)
      card = out[:claims].values.flatten.find { |c| c[:key] == "contribution" }
      expect(card[:value].length).to eq(51)
    end

    it "provenance returns the FULL claim value by default (the drill-down never truncates)" do
      out = call_tool("provenance", claim_id: claim.id)
      expect(out[:claim][:value]).to eq(long)
      expect(out[:claim][:truncated]).to be_nil
    end

    it "quote returns the full claim value alongside the source passage" do
      out = call_tool("quote", claim_id: claim.id)
      expect(out[:claim][:value]).to eq(long)
    end
  end

  describe "recent_activity" do
    it "answers the morning question: windowed digest with failures and a clamped window" do
      w = enliterate!("A", topic: "x")
      w.enliterator_visits.create!(facet: "summary", status: "failed", tier: "cheap",
                                   error: "gateway down", created_at: 1.hour.ago)

      out = call_tool("recent_activity", hours: 9_999)   # clamps to MAX_HOURS, no error
      expect(out[:window][:hours]).to be <= Enliterator::Mcp::Tools::RecentActivity::MAX_HOURS
      expect(out[:headline]).to be_present
      expect(out[:visits][:total]).to be >= 2
      expect(out[:failures][:sample].first[:error]).to eq("gateway down")
      expect(out[:next]).to be_present   # self-describing
    end
  end

  describe "the governed writes" do
    it "propose_term files a pending suggestion that rides authority control" do
      w = enliterate!("A")
      out = call_tool("propose_term", type: "Widget", id: w.id.to_s, facet: "summary",
                      key: "evidence_base", rationale: "front matter never states it")
      expect(out[:filed]).to be(true)
      s = Enliterator::Suggestion.find(out[:suggestion_id])
      expect(s.status).to eq("pending")
      expect(s.rationale).to start_with("mcp-agent: ")
      expect(out[:pressure]).to be >= 1
    end

    it "flag_claim reaches the review queue but changes NO accuracy number (the pin)" do
      w = enliterate!("A", advisor: "Dr. Voss")
      claim = w.enliterator_claims.find_by(key: "advisor")
      Enliterator::Audit.create!(claim: claim, source: "examiner", auditor: "t",
                                 verdict: "supported", rationale: "r")
      before_accuracy  = Enliterator::Audit.accuracy
      before_agreement = Enliterator::Audit.anchor_agreement

      out = call_tool("flag_claim", claim_id: claim.id, verdict: "contradicted",
                      note: "the source names a different advisor")
      expect(out[:flagged]).to be(true)

      expect(Enliterator::Audit.accuracy).to eq(before_accuracy)             # instrument untouched
      expect(Enliterator::Audit.anchor_agreement).to eq(before_agreement)
      # an unexamined claim with ONLY an agent flag still reaches the examiner's pool:
      fresh = enliterate!("B", advisor: "Dr. Other")
      fc = fresh.enliterator_claims.find_by(key: "advisor")
      call_tool("flag_claim", claim_id: fc.id, verdict: "unverifiable", note: "n")
      expect(Enliterator::Audit.candidate_scope).to include(fc)
      # and a supported claim needs no flag:
      expect { call_tool("flag_claim", claim_id: claim.id, verdict: "supported", note: "n") }
        .to raise_error(ArgumentError, /needs no flag/)
    end

    it "agent flags enter the human review queue" do
      w = enliterate!("A", advisor: "Dr. Voss")
      claim = w.enliterator_claims.find_by(key: "advisor")
      call_tool("flag_claim", claim_id: claim.id, verdict: "contradicted", note: "check the title page")

      get "/enliterator/review"
      expect(response.body).to include("agent: contradicted").and include("check the title page")
    end
  end
end
