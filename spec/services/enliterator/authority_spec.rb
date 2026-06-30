# frozen_string_literal: true

require "rails_helper"

# v0.51 — the authority file: the standing vocabulary as preferred terms + UF variant rings,
# with proliferation diagnostics. Context-scoped, queried live.
RSpec.describe Enliterator::Authority do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary,  tier: "cheap", terms: { summary: "s", authored_by: "a" }
        facet :coverage, tier: "cheap", terms: { concepts: "c" }
        facet :sig,      tier: "cheap", terms: { significance: "x" }
        ladder [ "cheap" ]
      end
    end
  end

  let(:w1) { Widget.create!(title: "1", body: "x") }
  let(:w2) { Widget.create!(title: "2", body: "y") }

  def sugg(key, status:, facet: "coverage", to: nil, on: nil)
    Enliterator::Suggestion.create!(tendable: on || w1, facet: facet, proposed_key: key,
                                    rationale: "r", status: status, mapped_to: to)
  end

  it "builds rings — a preferred term with its UF variants, ranked by sprawl" do
    sugg("case_studies", status: "approved")
    sugg("historical_examples", status: "mapped", to: "case_studies", facet: "coverage")
    sugg("worked_examples",     status: "mapped", to: "case_studies", facet: "summary")
    sugg("abstract",            status: "mapped", to: "summary",      facet: "summary")

    o  = described_class.new.overview
    cs = o[:rings].find { |r| r[:term] == "case_studies" }
    expect(cs[:approved]).to be(true)
    expect(cs[:canonical]).to be(true)
    expect(cs[:variants]).to contain_exactly("historical_examples", "worked_examples")
    expect(cs[:variant_count]).to eq(2)

    summ = o[:rings].find { |r| r[:term] == "summary" }   # a code term acting as a USE target
    expect(summ[:canonical]).to be(true)
    expect(summ[:approved]).to be(false)
    expect(summ[:variants]).to eq([ "abstract" ])

    expect(o[:rings].index(cs)).to be < o[:rings].index(summ)   # 2 variants before 1
  end

  it "flags a dumping ground — a term folding variants from many facets" do
    sugg("case_studies", status: "approved")
    sugg("a", status: "mapped", to: "case_studies", facet: "coverage")
    sugg("b", status: "mapped", to: "case_studies", facet: "summary")
    sugg("c", status: "mapped", to: "case_studies", facet: "sig")    # 3 facets ⇒ dumping ground

    cs = described_class.new.overview[:rings].find { |r| r[:term] == "case_studies" }
    expect(cs[:dumping_ground]).to be(true)
    expect(cs[:facets]).to contain_exactly("coverage", "summary", "sig")
  end

  it "computes the one-off tail and proliferation metrics (over ALL statuses)" do
    sugg("case_studies", status: "approved", on: w1)
    sugg("hist", status: "mapped", to: "case_studies", on: w1)
    sugg("oneoff", status: "pending", on: w2)

    m = described_class.new.overview[:metrics]
    expect(m[:preferred_terms]).to eq(1)
    expect(m[:variant_keys]).to eq(1)
    expect(m[:proliferation]).to eq(1.0)
    expect(m[:distinct_keys]).to eq(3)        # case_studies, hist, oneoff
    expect(m[:one_off_keys]).to eq(3)         # each seen on exactly 1 record
    expect(m[:one_off_pct]).to eq(100)
  end

  it "an approved preferred term with no variants still appears (empty ring)" do
    sugg("lonely", status: "approved")
    ring = described_class.new.overview[:rings].find { |r| r[:term] == "lonely" }
    expect(ring).to be_present
    expect(ring[:variants]).to eq([])
    expect(ring[:variant_count]).to eq(0)
  end

  it "exposes canonical_keys = the effective vocabulary (legal correction targets)" do
    expect(described_class.new.canonical_keys).to include("summary", "authored_by", "concepts", "significance")
  end

  it "the facet rollup is a plain, marshalable hash (no default proc)" do
    sugg("k", status: "pending", facet: "coverage")
    rollup = described_class.new.overview[:facets]
    expect { Marshal.dump(rollup) }.not_to raise_error
    expect(rollup["coverage"]["pending"]).to eq(1)
  end
end
