# frozen_string_literal: true

require "rails_helper"

# v0.84 — THE BASIS PAPER. Beside v0.75's digest, a visit records the
# COMPOSITION of the text its reader was given (which segment was catalog
# record, document text, AI summary, the engine's reading notes, and where
# each began) — dated at mint, so attribution never has to be inferred from
# the text as it stands later. Quote serves the same layout plus where the
# document's own text begins.
RSpec.describe "v0.84 source layout" do
  class LayoutReaderStub
    Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
    def model_id = "stub"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      Result.new(parsed: { "claims" => [ { "key" => "summary", "value" => "the count was redundant" } ],
                           "confidence" => 0.9 }, raw: {}, tokens: {})
    end
  end

  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # A host that declares its composition: title + description as catalog
  # record, then an AI summary.
  let(:declaring_host) do
    Class.new(Widget) do
      def self.name = "Widget"
      def enliterator_text_segments(facet:)
        [ { text: title, basis: "catalog_record" },
          { text: "An abstract.", basis: "catalog_record" },
          { text: body, basis: "ai_summary" } ]
      end
      def to_enliterator_text = enliterator_text_segments(facet: nil).map { |s| s[:text] }.join("\n\n")
    end
  end

  def staff!
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        assign :summary, tier: "cheap"
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(LayoutReaderStub.new)
  end

  def tend!(record)
    staff!
    Enliterator::Tending::Visitor.new(record, facet: "summary", embedder: embedder).call
  end

  it "stamps the declared composition on the visit, with offsets into what was read" do
    host  = declaring_host.create!(title: "Thesis", body: "A machine summary: the count was redundant.")
    visit = tend!(host)
    layout = visit.reload.input_refs["source_layout"]
    expect(layout.map { |s| s["basis"] }).to eq(%w[catalog_record catalog_record ai_summary])
    expect(layout.map { |s| s["start"] }).to eq([ 0, 8, 22 ])
    expect(host.enliterator_text(facet: "summary")[22, 10]).to eq("A machine ")
  end

  it "stamps the engine's own notebook boundary on an undeclared host" do
    w = Widget.create!(title: "Thesis", body: "Abstract.\n\n#{Enliterator::Part::NOTEBOOK_HEADER}\n\n## Method\nnotes")
    layout = tend!(w).reload.input_refs["source_layout"]
    expect(layout.map { |s| s["basis"] }).to eq(%w[undeclared reading_notes])
    expect(layout.last["start"]).to eq(w.enliterator_text.index(Enliterator::Part::NOTEBOOK_HEADER))
  end

  it "an undeclared host with no notebook stamps NOTHING — input_refs byte-identical" do
    visit = tend!(Widget.create!(title: "Plain", body: "just a body"))
    expect(visit.reload.input_refs.keys).not_to include("source_layout")
  end

  it "the back-compat path stamps it too" do
    host  = declaring_host.create!(title: "Thesis", body: "A machine summary.")
    visit = Enliterator::Tending::Visitor.new(host, facet: "summary", llm: LayoutReaderStub.new,
                                                    embedder: embedder).call
    expect(visit.reload.input_refs["source_layout"].last["basis"]).to eq("ai_summary")
  end

  describe "quote" do
    def call_tool(name, **args) = Enliterator::Mcp.dispatch(name, args.transform_keys(&:to_s))

    it "returns the layout and where the document's own text begins" do
      host  = declaring_host.create!(title: "Thesis", body: "A machine summary: the count was redundant.")
      tend!(host)
      claim = host.enliterator_claims.live.find_by(key: "summary")
      allow_any_instance_of(Enliterator::Claim).to receive(:tendable).and_return(declaring_host.find(host.id))

      out = call_tool("quote", claim_id: claim.id)
      expect(out[:basis]).to eq("ai_summary")
      expect(out[:body_at]).to eq(22)
      expect(out[:segments].map { |s| s[:basis] }).to eq(%w[catalog_record catalog_record ai_summary])
    end

    it "the excerpt never crosses out of the segment its span sits in" do
      host  = declaring_host.create!(title: "Thesis", body: "A machine summary: the count was redundant.")
      tend!(host)
      claim = host.enliterator_claims.live.find_by(key: "summary")
      allow_any_instance_of(Enliterator::Claim).to receive(:tendable).and_return(declaring_host.find(host.id))
      out = call_tool("quote", claim_id: claim.id)
      expect(out[:at_chars]).to eq(22)                       # clipped to the AI-summary segment's start
      expect(out[:passage]).to eq("A machine summary: the count was redundant.")
    end

    it "an undeclared host gets neither key (the v0.82 shape)" do
      w = Widget.create!(title: "Plain", body: "the count was redundant")
      tend!(w)
      out = call_tool("quote", claim_id: w.enliterator_claims.live.find_by(key: "summary").id)
      expect(out.keys).not_to include(:segments, :body_at)
    end
  end
end
