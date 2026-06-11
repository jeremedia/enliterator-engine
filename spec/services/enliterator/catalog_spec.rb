# frozen_string_literal: true

require "rails_helper"

# v0.24 — the Catalog: browse and search the enliterated holdings. The grid
# and search walk the embedding spine (Chat retrieval's pool); subject browse
# walks the claim store with heading counts CONGRUENT with their click-through
# totals (byte-exact terms, the jsonb-containment shapes and nothing else).
RSpec.describe Enliterator::Catalog do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def widget!(title, body: "b")
    Widget.create!(title: title, body: body)
  end

  def visit!(record, context: nil, at: Time.current)
    record.enliterator_visits.create!(facet: "summary", status: "succeeded",
                                      applied: true, tier: "cheap",
                                      context: context, created_at: at)
  end

  def claim!(record, key:, value:, context: nil, at: Time.current)
    record.enliterator_claims.create!(
      key: key, value: value, status: "draft", confidence: 0.8, context: context,
      visit: visit!(record, context: context, at: at), created_at: at, updated_at: at
    )
  end

  def embed!(rec)
    rec.enliterator_embeddings.create!(
      kind: "primary", embedding: embedder.embed(rec.enliterator_text),
      dimensions: embedder.dimensions, model: "null"
    )
  end

  def enliterate!(title, body: "b", **claims)
    w = widget!(title, body: body)
    claims.each { |k, v| claim!(w, key: k.to_s, value: v) }
    embed!(w)
    w
  end

  subject(:catalog) { described_class.new(embedder: embedder) }

  describe "#overview" do
    it "counts the holdings honestly: enliterated (the embedding spine), the corpus, understanding claims, keys in use" do
      a = enliterate!("Alpha", advisor: "Dr. Voss", summary: "About elections.")
      enliterate!("Beta", advisor: "Dr. Voss")
      widget!("Untended")                                       # in the corpus, not the catalog
      # A host-seeded catalog fact (no visit, not human:*) is NOT understanding:
      a.enliterator_claims.create!(key: "source_status", value: "ok", status: "draft")

      o = catalog.overview
      expect(o[:stats]).to eq(enliterated: 2, corpus: 3, live_claims: 3, vocabulary_keys: 2)
      expect(o[:types]).to eq("Widget" => 2)
    end

    it "counts the corpus through the visit log even when the registry is empty (dev lazy-loading)" do
      enliterate!("A", advisor: "Dr. Voss")
      widget!("Untended")
      allow(Enliterator).to receive(:tendable_models).and_return([])
      expect(catalog.overview[:stats][:corpus]).to eq(2)
    end

    it "offers subject headings from short claim values — scalars and string array elements, counted by DISTINCT RECORD" do
      a = enliterate!("A", advisor: "Dr. Voss", keywords: [ "elections", "continuity" ])
      enliterate!("B", advisor: "Dr. Voss", keywords: [ "elections" ])
      # The same record asserting the same heading in a context is still ONE record:
      ctx = Enliterator::Context.create!(key: "es", name: "ES")
      a.place_in_context!(ctx)
      claim!(a, key: "advisor", value: "Dr. Voss", context: ctx)

      headings = catalog.overview[:headings]
      advisor  = headings.find { |h| h[:key] == "advisor" }
      keywords = headings.find { |h| h[:key] == "keywords" }
      expect(advisor[:values]).to include([ "Dr. Voss", 2 ])
      expect(keywords[:values]).to include([ "elections", 2 ], [ "continuity", 1 ])
    end

    it "prose keys, identifier-like keys, and hash-shaped values never become headings" do
      a = enliterate!("A", summary: "A long faithful abstract of the work. " * 8,
                           eo_number: "13129", advisor: "Dr. Voss")
      enliterate!("B", eo_number: "14000", advisor: "Dr. Voss")
      claim!(a, key: "legislation", value: [ { "type" => "act", "designation" => "Stafford Act" } ])

      keys = catalog.overview[:headings].map { |h| h[:key] }
      expect(keys).to eq([ "advisor" ])   # summary = prose; eo_number = all-unique; legislation = hashes
    end

    it "lists the latest tended RECORDS (escalation dedupes), newest first" do
      old = enliterate!("Old"); new_rec = enliterate!("New")
      visit!(old, at: 2.days.ago)
      visit!(new_rec, at: 1.hour.ago)
      visit!(new_rec, at: 30.minutes.ago)   # second visit, same record

      recent = catalog.overview[:recent]
      expect(recent.map { |r| r[:label] }).to eq([ "New", "Old" ])
    end
  end

  describe "heading ↔ filter congruence (the load-bearing pin)" do
    it "every offered heading's count equals its click-through total — including array elements and byte-exact values" do
      enliterate!("A", advisor: " Dr. Voss", keywords: [ "elections", "trafficking" ])
      enliterate!("B", advisor: " Dr. Voss", keywords: [ "elections" ])
      enliterate!("C", keywords: [ "trafficking" ])

      catalog.overview[:headings].each do |h|
        h[:values].each do |(term, n)|
          expect(catalog.subject(h[:key], term)[:total]).to eq(n),
            "heading #{h[:key]}=#{term.inspect} promised #{n}"
        end
      end
      # The leading space is stored; the heading must carry it byte-exact:
      expect(catalog.subject("advisor", " Dr. Voss")[:total]).to eq(2)
      expect(catalog.subject("advisor", "Dr. Voss")[:total]).to eq(0)
    end
  end

  describe "#subject" do
    it "matches a scalar value and an array element; hash shapes are unfilterable and unoffered" do
      a = enliterate!("A", advisor: "Dr. Voss")
      b = enliterate!("B", keywords: [ "elections", "continuity" ])
      claim!(a, key: "legislation", value: [ { "designation" => "Stafford Act" } ])

      expect(catalog.subject("advisor", "Dr. Voss")[:records].map { |c| c[:label] }).to eq([ "A" ])
      expect(catalog.subject("keywords", "elections")[:records].map { |c| c[:label] }).to eq([ "B" ])
      expect(catalog.subject("legislation", "Stafford Act")[:total]).to eq(0)
      expect(b).to be_persisted
    end

    it "within a context, a NON-MEMBER's root claim does not leak — counts and results agree" do
      ctx    = Enliterator::Context.create!(key: "es", name: "Election Security")
      member = enliterate!("Member", advisor: "Dr. Voss")
      member.place_in_context!(ctx)
      enliterate!("Outsider", advisor: "Dr. Voss")   # root claim, not a member

      scoped = described_class.new(context: ctx, embedder: embedder)
      result = scoped.subject("advisor", "Dr. Voss")
      expect(result[:total]).to eq(1)
      expect(result[:records].map { |c| c[:label] }).to eq([ "Member" ])
      advisor = scoped.overview[:headings].find { |h| h[:key] == "advisor" }
      expect(advisor[:values]).to include([ "Dr. Voss", 1 ])
    end
  end

  describe "#page (the grid)" do
    it "walks the spine in accession order, newest first, with honest pagination math" do
      stub_const("Enliterator::Catalog::PER_PAGE", 2)
      %w[First Second Third].each { |t| enliterate!(t, advisor: "Dr. X") }

      p1 = catalog.page(1)
      expect(p1[:records].map { |c| c[:label] }).to eq([ "Third", "Second" ])
      expect(p1.slice(:page, :pages, :total)).to eq(page: 1, pages: 2, total: 3)
      expect(catalog.page(2)[:records].map { |c| c[:label] }).to eq([ "First" ])
      expect(catalog.page(99)[:page]).to eq(2)    # clamped, never blank
      expect(catalog.page(0)[:page]).to eq(1)
    end

    it "hydrates the understanding onto each card: claims, tending depth, contexts, last visit" do
      ctx = Enliterator::Context.create!(key: "es", name: "Election Security")
      w   = enliterate!("Continuity of Operations",
                        summary: "How county clerks keep elections running.",
                        advisor: "Dr. Voss")
      w.place_in_context!(ctx)

      card = catalog.page(1)[:records].first
      expect(card).to include(type: "Widget", id: w.id.to_s,
                              label: "Continuity of Operations",
                              claim_count: 2, visit_count: 2,
                              contexts: [ "Election Security" ])
      expect(card[:excerpt]).to eq("How county clerks keep elections running.")
      expect(card[:last_visit_at]).to be_within(5.seconds).of(Time.current)
    end

    it "the excerpt prefers a summary-like claim, then the longest prose claim, then the record's own text" do
      no_summary = enliterate!("NoSummary", advisor: "Dr. Voss",
                               key_findings: "A longer finding than the advisor string, surely.")
      bare       = widget!("Bare", body: "the source text itself")
      embed!(bare)

      cards = catalog.page(1)[:records].index_by { |c| c[:label] }
      expect(cards["NoSummary"][:excerpt]).to start_with("A longer finding")
      expect(cards["Bare"][:excerpt]).to include("the source text itself")
    end
  end

  describe "#search (by meaning)" do
    it "returns the nearest records with distances, scoped by context membership and type" do
      a = enliterate!("Alpha", body: "human trafficking and disaster response")
      enliterate!("Beta",  body: "wildfire fuel management")

      hits = catalog.search("human trafficking")[:records]
      expect(hits.first[:label]).to eq("Alpha")
      expect(hits.first[:distance]).to be_a(Numeric)

      ctx = Enliterator::Context.create!(key: "es", name: "ES")
      a.place_in_context!(ctx)
      scoped = described_class.new(context: ctx, embedder: embedder)
      expect(scoped.search("anything")[:records].map { |c| c[:label] }).to eq([ "Alpha" ])
    end

    it "degrades honestly: a dead embedder names itself instead of faking results" do
      enliterate!("Alpha")
      dead = Class.new { def embed(_q) = nil }.new
      expect(described_class.new(embedder: dead).search("x"))
        .to eq(records: [], degraded: "no-vector")
    end

    it "degrades honestly on the Null embedder outside specs (its pseudo-vectors would LOOK like results)" do
      Enliterator.configuration.allow_null_llm = false
      expect(catalog.search("x")).to eq(records: [], degraded: "null-embedder")
    ensure
      Enliterator.configuration.allow_null_llm = true
    end
  end

  describe "#wander (the open stacks)" do
    it "lands on a random enliterated record, and admits when there is nowhere to go" do
      expect(catalog.wander).to be_nil
      w = enliterate!("Somewhere")
      expect(catalog.wander).to eq([ "Widget", w.id.to_s ])
    end
  end

  describe "the cached overview (v0.20 idiom)" do
    around do |ex|
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      ex.run
    ensure
      Rails.cache = original
    end

    it "serves from cache until a cycle lands, then republishes (the key carries the cycle id)" do
      enliterate!("A", advisor: "Dr. Voss")
      first = described_class.new(embedder: embedder).overview
      expect(first[:stats][:enliterated]).to eq(1)

      enliterate!("B", advisor: "Dr. Voss")   # the collection moves...
      cached = described_class.new(embedder: embedder).overview
      expect(cached[:stats][:enliterated]).to eq(1)   # ...but the page reads the ledger

      Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 100,
                                     planned: {}, started_at: Time.current)
      expect(described_class.new(embedder: embedder).overview[:stats][:enliterated]).to eq(2)
    end
  end
end
