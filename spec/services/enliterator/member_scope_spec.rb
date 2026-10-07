# frozen_string_literal: true

require "rails_helper"

# v0.83 — THE AUDIENCE SCOPE. A host serving readers of different
# entitlements wraps each read in Enliterator.with_member_scope(relation);
# inside, only those records exist — before any count or rank is computed.
# A withheld record must not appear in a heading count, a search result, a
# connection edge, a neighbor list, or as a distinguishable "not found".
RSpec.describe "v0.83 audience scope" do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def call_tool(name, **args) = Enliterator::Mcp.dispatch(name, args.transform_keys(&:to_s))

  # A record with a heading-bearing claim and a primary embedding.
  def holding!(title, topic: "election security")
    w = Widget.create!(title: title, body: "about #{topic}")
    visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    w.enliterator_claims.create!(key: "keywords", value: [ topic ], status: "draft", confidence: 0.8, visit: visit)
    w.enliterator_embeddings.create!(kind: "primary", embedding: embedder.embed(w.enliterator_text),
                                     dimensions: embedder.dimensions, model: "null")
    w
  end

  let!(:open_a)   { holding!("Open A") }
  let!(:open_b)   { holding!("Open B") }
  let!(:withheld) { holding!("Withheld C") }
  let(:visible)   { Widget.where(id: [ open_a.id, open_b.id ]) }

  def with_scope(&block) = Enliterator.with_member_scope(visible, &block)

  def heading_count(result, value)
    h = result[:headings].find { |x| x[:key] == "keywords" }
    h && h[:values].to_h[value]
  end

  it "no scope: byte-identical — every record counts" do
    expect(heading_count(call_tool("browse_subjects"), "election security")).to eq(3)
  end

  it "subject-heading COUNTS exclude withheld records — before counting, not after" do
    unscoped = call_tool("browse_subjects")          # warms the unscoped cache
    scoped   = with_scope { call_tool("browse_subjects") }
    expect(heading_count(scoped, "election security")).to eq(2)
    expect(heading_count(unscoped, "election security")).to eq(3)  # two audiences, two cache entries
  end

  it "the subject click-through total equals the scoped count (the v0.24 congruence holds per audience)" do
    out = with_scope { call_tool("subject_search", key: "keywords", value: "election security") }
    expect(out[:total]).to eq(2)
    expect(out[:records].map { |r| r[:id] }).not_to include(withheld.id.to_s)
  end

  it "the embedding pool (grid, search, neighbors) holds only visible records" do
    ids = with_scope { Enliterator::Embedding.where(kind: "primary").in_context(nil).pluck(:embeddable_id) }
    expect(ids).to contain_exactly(open_a.id.to_s, open_b.id.to_s)
  end

  it "a withheld record answers EXACTLY like a missing one — no existence oracle" do
    missing = expect { with_scope { call_tool("record_entry", type: "Widget", id: "999999") } }
    missing.to raise_error(ArgumentError, /no Widget with id/)
    expect { with_scope { call_tool("record_entry", type: "Widget", id: withheld.id.to_s) } }
      .to raise_error(ArgumentError, "no Widget with id #{withheld.id.to_s.inspect}")
  end

  it "claim-addressed tools refuse a withheld record's claim the same way as a missing claim" do
    claim = withheld.enliterator_claims.first
    expect { with_scope { call_tool("quote", claim_id: claim.id) } }
      .to raise_error(ArgumentError, "no claim ##{claim.id}")
    expect { with_scope { call_tool("provenance", claim_id: claim.id) } }
      .to raise_error(ArgumentError, "no claim ##{claim.id}")
  end

  it "visible records still read normally inside the scope" do
    out = with_scope { call_tool("record_entry", type: "Widget", id: open_a.id.to_s) }
    expect(out[:label]).to eq("Open A")
  end

  it "types the scope does not name are ABSENT — deny by default" do
    other = Enliterator::Context.create!(key: "x", name: "X") # a non-Widget row type isn't a tendable;
    expect(Enliterator::MemberScope.include?(open_a)).to be(true)  # no scope: everything visible
    Enliterator.with_member_scope(Widget.where(id: open_a.id)) do
      expect(Enliterator::MemberScope.include?(open_b)).to be(false)
    end
    expect(other).to be_persisted
  end

  it "a Part follows its record" do
    part = Enliterator::Part.create!(record: withheld, ordinal: 0, heading: "H", text: "t",
                                     content_digest: "d", char_start: 0, char_end: 1)
    with_scope { expect(Enliterator::MemberScope.include?(part)).to be(false) }
  end

  it "FAILS CLOSED: a tool that does not honor the scope refuses to run inside one" do
    expect { with_scope { call_tool("recent_activity") } }
      .to raise_error(Enliterator::Mcp::ScopeNotHonored, /recent_activity does not honor/)
    expect { call_tool("recent_activity") }.not_to raise_error   # outside, unchanged
  end

  describe "collection_overview" do
    it "counts only visible records, and leaves the whole-collection rollups out" do
      full   = call_tool("collection_overview")
      scoped = with_scope { call_tool("collection_overview") }
      expect(full[:stats][:enliterated]).to eq(3)
      expect(scoped[:stats][:enliterated]).to eq(2)
      expect(scoped[:stats][:corpus]).to eq(2)
      expect(scoped[:types]).to eq("Widget" => 2)
      expect(scoped.keys).not_to include(:condition, :accuracy)
      expect(full.keys).to include(:condition, :accuracy)   # unscoped: byte-identical shape
    end

    it "facet tended counts and context membership are the reader's" do
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :summary, tier: "cheap", terms: { summary: "An abstract." }
          ladder [ "cheap" ]
        end
      end
      ctx = Enliterator::Context.create!(key: "shelf", name: "Shelf")
      [ open_a, withheld ].each { |w| ctx.memberships.create!(member_type: "Widget", member_id: w.id.to_s) }
      scoped = with_scope { call_tool("collection_overview") }
      shelf  = scoped[:contexts].find { |c| c[:key] == "shelf" }
      expect(shelf).to include(members: 1, direct_members: 1)
      summary = scoped[:facets].find { |f| f[:facet] == "summary" }
      expect(summary[:tended_count]).to eq(2)
    end
  end

  it "vocabulary reads no records, so it runs unchanged inside a scope" do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
    end
    expect(with_scope { call_tool("vocabulary") }).to eq(call_tool("vocabulary"))
  end

  it "connections drop edges to records the reader may not see" do
    a, b, c = [ open_a, open_b, withheld ].map { |w| "r:Widget:#{w.id}" }
    allow(Enliterator::Atlas).to receive(:edge_index).and_return(
      index: {}, bearing: [],
      labels: { a => "Open A", b => "Open B", c => "Withheld C" },
      inbound: { a => [ { s: b, t: a, key: "related", w: 0.9 }, { s: c, t: a, key: "related", w: 0.8 } ] }
    )
    out = with_scope { call_tool("connections", type: "Widget", id: open_a.id.to_s) }
    labels = out[:edges].map { |e| e[:target][:label] }
    expect(labels).to include("Open B")
    expect(labels).not_to include("Withheld C")
  end

  it "the scope is restored after the block, even on error" do
    expect { with_scope { raise "boom" } }.to raise_error("boom")
    expect(Enliterator::MemberScope.active?).to be(false)
  end
end
