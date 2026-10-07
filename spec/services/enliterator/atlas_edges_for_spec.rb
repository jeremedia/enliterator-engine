# frozen_string_literal: true

require "rails_helper"

# v0.85 — ONE RECORD'S EDGES, UNCAPPED. The drawn Atlas caps nodes; a record
# past the cap is not drawn and a drawn record can lose edges. edges_for
# answers one record's edges, in and out, from the same resolution index and
# typed-edge rule — no cap, no thinning.
RSpec.describe "Enliterator::Atlas.edges_for" do
  def claim!(record, key:, value:, confidence: 0.8)
    visit = record.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    record.enliterator_claims.create!(key: key, value: value, status: "draft", tier: "cheap",
                                      confidence: confidence, visit: visit)
  end

  let!(:alpha) { Widget.create!(title: "Alpha Thesis", body: "b") }
  let!(:beta)  { Widget.create!(title: "Beta Thesis", body: "b") }
  let!(:gamma) { Widget.create!(title: "Gamma Thesis", body: "b") }

  before do
    claim!(alpha, key: "related_theses", value: [ "Beta Thesis" ], confidence: 0.9)
    claim!(alpha, key: "advisor", value: "Dr. Voss")
    claim!(gamma, key: "related_theses", value: [ "Alpha Thesis" ], confidence: 0.6)
    # Crowd the graph so a small node cap leaves records out of the drawing.
    6.times { |i| claim!(beta, key: "advisor", value: "Dr. Crowd #{i}") }
  end

  def node(w) = "r:Widget:#{w.id}"

  it "returns edges in AND out, resolved, strongest first, with labels" do
    out = Enliterator::Atlas.edges_for(type: "Widget", id: alpha.id)
    expect(out[:node]).to eq(node(alpha))
    expect(out[:edges].map { |e| [ e[:s], e[:t], e[:key] ] }).to eq([
      [ node(alpha), node(beta), "related_theses" ],
      [ node(alpha), "e:dr. voss", "advisor" ],
      [ node(gamma), node(alpha), "related_theses" ]
    ])
    expect(out[:labels][node(gamma)]).to eq("Gamma Thesis")
    expect(out[:labels]["e:dr. voss"]).to eq("Dr. Voss")
  end

  it "answers for a record the node-capped drawing leaves out" do
    drawn = Enliterator::Atlas.assemble(node_cap: 2)   # keeps the two most-connected (beta, alpha)
    expect(drawn[:nodes].map { |n| n[:id] }).not_to include(node(gamma))
    out = Enliterator::Atlas.edges_for(type: "Widget", id: gamma.id)
    expect(out[:edges].map { |e| e[:t] }).to eq([ node(alpha) ])
  end

  it "agrees with the uncapped drawing — one edge rule, two views" do
    drawn = Enliterator::Atlas.assemble(node_cap: 10_000)[:edges]
              .select { |e| e[:s] == node(alpha) || e[:t] == node(alpha) }
              .reject { |e| e[:key] == "in-context" }
    ours = Enliterator::Atlas.edges_for(type: "Widget", id: alpha.id)[:edges]
    expect(ours.map { |e| e.slice(:s, :t, :key, :w) }).to match_array(drawn.map { |e| e.slice(:s, :t, :key, :w) })
  end

  it "under an audience scope, edges touching a withheld record are absent — and a withheld record has none" do
    Enliterator.with_member_scope(Widget.where(id: [ alpha.id, beta.id ])) do
      ours = Enliterator::Atlas.edges_for(type: "Widget", id: alpha.id)[:edges]
      expect(ours.map { |e| e[:s] }).not_to include(node(gamma))
      expect(Enliterator::Atlas.edges_for(type: "Widget", id: gamma.id)[:edges]).to be_empty
    end
  end

  it "the connections tool reports the uncapped total" do
    out = Enliterator::Mcp.dispatch("connections", "type" => "Widget", "id" => alpha.id.to_s)
    expect(out[:edges_total]).to eq(3)
    expect(out[:edges].map { |e| e[:direction] }).to eq(%w[out out in])
  end
end
