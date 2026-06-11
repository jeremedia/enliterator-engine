# frozen_string_literal: true

require "rails_helper"

# v0.21 — the Atlas: the claim store drawn as a labeled property graph.
# Records are nodes; entity-bearing claims are typed edges with provenance;
# strings resolve to records through the unique-claim-value index.
RSpec.describe Enliterator::Atlas do
  def visit!(record, facet: "summary", tier: "cheap")
    record.enliterator_visits.create!(facet: facet, status: "succeeded", applied: true, tier: tier)
  end

  def claim!(record, key:, value:, tier: "cheap", confidence: 0.8, context: nil, at: Time.current)
    record.enliterator_claims.create!(
      key: key, value: value, status: "draft", tier: tier, confidence: confidence,
      context: context, visit: visit!(record, tier: tier), created_at: at, updated_at: at
    )
  end

  def node(atlas, id)  = atlas[:nodes].find { |n| n[:id] == id }
  def edge(atlas, key) = atlas[:edges].find { |e| e[:key] == key }

  it "rolls analytical entries up: a part's claims draw from the PARENT work's node, never a part node (v0.26.1)" do
    w    = Widget.create!(title: "Deep Thesis", body: "b")
    part = Enliterator::Part.refresh_for!(w, [ { heading: "Lit Review", text: "alpha" } ]).first
    claim!(part, key: "cited_works", value: [ "Bruce Hoffman, Inside Terrorism" ])
    claim!(w, key: "advisor", value: "Dr. Voss")

    atlas = described_class.assemble
    expect(atlas[:nodes].map { |n| n[:id] }.grep(/\Ar:Enliterator::Part/)).to be_empty
    cited = edge(atlas, "cited_works")
    expect(cited[:s]).to eq("r:Widget:#{w.id}")             # the WORK carries the citation edge
    expect(node(atlas, "e:bruce hoffman, inside terrorism")).to be_present
    expect(node(atlas, "r:Widget:#{w.id}")[:size]).to eq(2) # work + part claims, one node
  end

  it "draws records as nodes and entity-bearing claims as typed edges" do
    w = Widget.create!(title: "Continuity of Operations", body: "b")
    claim!(w, key: "advisor", value: "Dr. Mara Voss")
    claim!(w, key: "thematic_cluster", value: "Election Infrastructure")

    atlas = described_class.assemble
    rec = node(atlas, "r:Widget:#{w.id}")
    expect(rec).to include(kind: "record", label: "Continuity of Operations")
    expect(node(atlas, "e:dr. mara voss")).to include(kind: "entity", label: "Dr. Mara Voss", group: "advisor")
    expect(edge(atlas, "advisor")).to include(s: rec[:id], t: "e:dr. mara voss", w: 0.8)
    expect(atlas[:meta][:records]).to eq(1)
    expect(atlas[:meta][:entities]).to eq(2)
  end

  it "resolves strings to records through the unique-claim-value index (supersedes → eo_number), with no identity self-edges" do
    old_eo = Widget.create!(title: "EO 13129", body: "b")
    new_eo = Widget.create!(title: "EO 14000", body: "b")
    claim!(old_eo, key: "eo_number", value: "13129")
    claim!(new_eo, key: "eo_number", value: "14000")
    claim!(new_eo, key: "supersedes", value: [ "13129" ])

    atlas = described_class.assemble
    sup = edge(atlas, "supersedes")
    expect(sup).to include(s: "r:Widget:#{new_eo.id}", t: "r:Widget:#{old_eo.id}")
    # eo_number self-resolves: identity claims feed the index, draw nothing.
    expect(edge(atlas, "eo_number")).to be_nil
    expect(node(atlas, "e:13129")).to be_nil
  end

  it "leaves a COLLIDING value unresolved — a string two records share can't name one" do
    a = Widget.create!(title: "A", body: "b")
    b = Widget.create!(title: "B", body: "b")
    claim!(a, key: "report_number", value: "GAO-12-114")
    claim!(b, key: "report_number", value: "GAO-12-114")
    c = Widget.create!(title: "C", body: "b")
    claim!(c, key: "references", value: [ "GAO-12-114" ])

    atlas = described_class.assemble
    expect(edge(atlas, "references")[:t]).to eq("e:gao-12-114")   # entity, not a wrong record
  end

  it "tolerates the value shapes claims actually hold (string / array / array-of-hashes)" do
    w = Widget.create!(title: "Mixed", body: "b")
    claim!(w, key: "legislation_referenced",
              value: [ { "type" => "act", "designation" => "Stafford Act" }, "P.L. 114-53" ])

    atlas = described_class.assemble
    expect(node(atlas, "e:stafford act")).to be_present
    expect(node(atlas, "e:p.l. 114-53")).to be_present
    expect(atlas[:edges].count { |e| e[:key] == "legislation_referenced" }).to eq(2)
  end

  it "prose keys fall out adaptively — no denylist" do
    w = Widget.create!(title: "Prose", body: "b")
    claim!(w, key: "summary", value: "A long faithful abstract " * 20)
    claim!(w, key: "advisor", value: "Dr. Short")

    atlas = described_class.assemble
    expect(atlas[:edges].map { |e| e[:key] }).to contain_exactly("advisor")
  end

  it "excludes condition flags and host seeds, keeps curator corrections" do
    w = Widget.create!(title: "Flags", body: "b")
    claim!(w, key: "advisor", value: "Kept Advisor")
    w.enliterator_claims.create!(key: "source_status", value: "url_dead", status: "verified",
                                 locked: true, attributed_to: "condition-survey")   # the 8,317
    w.assert_claim!(key: "host_seed", value: "Catalog Fact")                          # host seed
    w.enliterator_claims.create!(key: "corrected_author", value: "Human Fix", status: "verified",
                                 locked: true, attributed_to: "human:fixed on review")

    atlas = described_class.assemble
    keys = atlas[:edges].map { |e| e[:key] }
    expect(keys).to include("advisor", "corrected_author")
    expect(keys).not_to include("source_status", "host_seed")
  end

  it "dedups repeated edges (max confidence wins) and entities across keys" do
    w  = Widget.create!(title: "W", body: "b")
    w2 = Widget.create!(title: "W2", body: "b")
    claim!(w,  key: "affected_agencies", value: [ "DHS" ], confidence: 0.6)
    claim!(w,  key: "affected_agencies", value: [ "DHS" ], confidence: 0.9)
    claim!(w2, key: "agencies_directed", value: [ "DHS" ])

    atlas = described_class.assemble
    expect(atlas[:nodes].count { |n| n[:id] == "e:dhs" }).to eq(1)
    expect(atlas[:edges].count { |e| e[:t] == "e:dhs" }).to eq(2)   # one per (record, key)
    expect(atlas[:edges].find { |e| e[:s] == "r:Widget:#{w.id}" && e[:t] == "e:dhs" }[:w]).to eq(0.9)
  end

  it "carries provenance on edges: timestamp, tier, and the audit verdict where one exists" do
    w = Widget.create!(title: "Audited", body: "b")
    t = Time.current - 2.days
    c = claim!(w, key: "advisor", value: "Dr. Verdict", tier: "quality", at: t)
    Enliterator::Audit.create!(claim: c, verdict: "supported", source: "examiner")

    atlas = described_class.assemble
    e = edge(atlas, "advisor")
    expect(e[:at]).to eq(t.to_i)
    expect(e[:tier]).to eq("quality")
    expect(e[:verdict]).to eq("examiner:supported")
  end

  it "scopes to a context (the v0.13 cumulative read) and hangs records on context diamonds" do
    ctx   = Enliterator::Context.create!(key: "election-security", name: "Election Security")
    other = Enliterator::Context.create!(key: "elsewhere", name: "Elsewhere")
    inside  = Widget.create!(title: "Inside", body: "b")
    outside = Widget.create!(title: "Outside", body: "b")
    claim!(inside,  key: "advisor", value: "Dr. In",  context: ctx)
    claim!(outside, key: "advisor", value: "Dr. Out", context: other)

    atlas = described_class.assemble(context: ctx)
    labels = atlas[:nodes].map { |n| n[:label] }
    expect(labels).to include("Inside", "Election Security")
    expect(labels).not_to include("Outside")
    expect(edge(atlas, "in-context")).to include(t: "c:election-security")
    expect(atlas[:meta][:context]).to eq("election-security")
  end

  it "caps to the most-connected nodes and says so" do
    hub = Widget.create!(title: "Hub", body: "b")
    claim!(hub, key: "keywords", value: (1..6).map { |i| "topic #{i}" })

    atlas = described_class.assemble(node_cap: 4)
    expect(atlas[:nodes].size).to eq(4)
    expect(atlas[:meta][:warnings].first).to include("4 most-connected")
    ids = atlas[:nodes].map { |n| n[:id] }.to_set
    expect(atlas[:edges]).to all(satisfy { |e| ids.include?(e[:s]) && ids.include?(e[:t]) })
  end

  it "renders an honest empty atlas when nothing is tended" do
    atlas = described_class.assemble
    expect(atlas[:nodes]).to eq([])
    expect(atlas[:meta][:claims_considered]).to eq(0)
  end

  it "serves build from the cache, keyed by the latest heartbeat (v0.20 idiom)" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    begin
      expect(described_class).to receive(:assemble).twice.and_call_original
      described_class.build
      described_class.build   # cache hit
      Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 100, planned: {},
                                     started_at: Time.current)
      described_class.build   # key busted by the new cycle
    ensure
      Rails.cache = original
    end
  end
end
