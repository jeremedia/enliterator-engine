# frozen_string_literal: true

require "rails_helper"

# Stage 1 of the Atlas research-instrument redesign: the inspector's data source.
# Atlas.inspect returns one node's live claims with provenance, plus any open
# lacunae (known gaps) when record_lacunae is on. Records carry claims/lacunae;
# entity nodes return an empty shell and the client falls back to its edge summary.
RSpec.describe "Enliterator::Atlas.inspect" do
  let(:widget) { Widget.create!(title: "Thesis A", body: "x") }

  def claim!(key:, value:, **attrs)
    v = widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    widget.enliterator_claims.create!(
      { key: key, value: value, status: "draft", confidence: 0.9,
        attributed_to: "cheap:x", tier: "cheap", visit: v, context_id: nil }.merge(attrs)
    )
  end

  it "returns the node's live claims with provenance" do
    claim!(key: "summary", value: "A concise account.")
    result = Enliterator::Atlas.inspect(type: "Widget", id: widget.id, context: nil)
    expect(result[:node][:label]).to eq("Thesis A")
    expect(result[:node][:path]).to eq("status/Widget/#{widget.id}")
    summary = result[:claims].find { |c| c[:key] == "summary" }
    expect(summary[:value]).to eq("A concise account.")
    expect(summary[:tier]).to eq("cheap")
    expect(summary[:confidence]).to eq(0.9)
    expect(summary[:asserted_at]).to be_a(Integer)
  end

  it "includes open lacunae as known gaps" do
    Enliterator.configure { |c| c.record_lacunae = true }
    Enliterator::Lacuna.open_or_refresh(tendable: widget, facet: "authorship", key: "authored_by",
                                        context: nil, diagnosis: "defective_surrogate", note: "byline dropped")
    result = Enliterator::Atlas.inspect(type: "Widget", id: widget.id, context: nil)
    gap = result[:lacunae].find { |l| l[:key] == "authored_by" }
    expect(gap[:diagnosis]).to eq("defective_surrogate")
    expect(gap[:note]).to eq("byline dropped")
  end

  it "returns an empty shell for an unknown record" do
    result = Enliterator::Atlas.inspect(type: "Widget", id: 0, context: nil)
    expect(result[:claims]).to eq([])
    expect(result[:lacunae]).to eq([])
  end
end
