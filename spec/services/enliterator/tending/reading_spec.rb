# frozen_string_literal: true

require "rails_helper"

# v0.25 — the Reading: one librarian's session over one record. Sections via
# the host contract, each part tended on the analysis facet (skip-if-fresh —
# the v0.14 economics applied inside the document), part embeddings filed
# under kind "part", then the work-level facets re-tended (the synthesis).
RSpec.describe Enliterator::Tending::Reading do
  # Conforms to the LLM contract (visitor_spec's stub pattern): every #tend
  # files one argument claim and counts its calls.
  class ReadingStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    attr_reader :calls, :facets_seen

    def initialize
      @calls = 0
      @facets_seen = []
    end

    def model_id = "stub-reader"

    def tend(text:, facet:, state:, neighbors:)
      @calls += 1
      @facets_seen << facet
      Result.new(
        parsed: { "claims" => [ { "key" => "argument", "op" => "ADD",
                                  "value" => "claim from call #{@calls}", "confidence" => 0.8 } ],
                  "confidence" => 0.8 },
        raw: {}, tokens: { "input" => 10, "output" => 5, "total" => 15 }
      )
    end
  end

  class ExplodingStubLLM
    def model_id = "stub-exploding"
    def tend(text:, facet:, state:, neighbors:)
      raise "gateway down"
    end
  end

  let(:llm)      { ReadingStubLLM.new }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }
  let(:widget) do
    Widget.create!(title: "Continuity Thesis",
                   body: "## Introduction\nWhy continuity matters in county elections.\n" \
                         "## Method\nA comparative case study of three counties.")
  end

  def reading(record = widget, **opts)
    described_class.new(record, llm: llm, embedder: embedder, **opts)
  end

  it "sections the record, tends every part on the analysis facet, and files the notes on the parts" do
    summary = reading.call

    expect(summary).to include(parts: 2, tended: 2, skipped: 0, failed: 0, synthesized: 0)
    expect(summary[:tokens]).to eq(30)
    parts = Enliterator::Part.where(record: widget).order(:ordinal)
    expect(parts.map(&:heading)).to eq([ "Introduction", "Method" ])
    parts.each do |part|
      expect(part.enliterator_claims.live.pluck(:key)).to eq([ "argument" ])
      expect(part.enliterator_visits.where(facet: "analysis", reason: "deep_read")).to be_present
    end
  end

  it "skips fresh parts on a re-read (unchanged sections cost nothing) and re-reads a changed one" do
    reading.call
    expect(reading.call).to include(tended: 0, skipped: 2)
    expect(llm.calls).to eq(2)   # only the first session spent

    widget.update!(body: widget.body.sub("three counties", "five counties"))
    expect(reading.call).to include(tended: 1, skipped: 1)
  end

  it "embeds each part once per content version, under kind 'part' — never 'primary'" do
    reading.call
    reading.call
    embeddings = Enliterator::Embedding.where(embeddable_type: "Enliterator::Part")
    expect(embeddings.count).to eq(2)
    expect(embeddings.pluck(:kind).uniq).to eq([ "part" ])
    expect(embeddings.first.content_hash).to be_present
  end

  it "synthesizes: re-tends the listed work-level facets on the RECORD, reason stamped" do
    summary = reading(synthesizes: %w[summary significance]).call
    expect(summary).to include(synthesized: 2)
    expect(widget.enliterator_visits.where(facet: %w[summary significance], reason: "deep_read").count).to eq(2)
    expect(llm.facets_seen.last(2)).to eq(%w[summary significance])
  end

  it "an exploding embedder cannot kill the reading — the notes still land (v0.26.2)" do
    boom = Class.new do
      def embed(_text) = raise("gateway rotating")
      def dimensions = 1536
    end.new
    summary = described_class.new(widget, llm: llm, embedder: boom).call
    expect(summary).to include(tended: 2, failed: 0, embedded: 0)
    expect(Enliterator::Part.where(record: widget).first.enliterator_claims.live).to be_present
  end

  it "skips honestly when the host yields no parts" do
    bare = Widget.create!(title: "Bare", body: "")
    expect(reading(bare).call).to eq(skipped: :no_parts)
    expect(Enliterator::Part.where(record: bare)).to be_empty
  end

  it "counts failures and stands down after three straight failed reads (misconfiguration, not bad luck)" do
    many = Widget.create!(title: "Many", body: (1..4).map { |i| "## S#{i}\ntext #{i}" }.join("\n"))
    summary = described_class.new(many, llm: ExplodingStubLLM.new, embedder: embedder).call
    expect(summary[:failed]).to eq(3)
    expect(summary[:aborted]).to include("first 3 reads failed")
    expect(summary[:tended]).to eq(0)
  end
end
