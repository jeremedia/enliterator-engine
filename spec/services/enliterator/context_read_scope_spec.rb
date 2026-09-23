# frozen_string_literal: true

require "rails_helper"

# v0.78 — a parent context reads its subtree. The v0.13 root rule made the ROOT
# view the unfiltered union; a named PARENT with no direct holdings (HSDL's `hsdl`
# federation anchor over chds-theses / crs-reports / executive-orders /
# election-security) read as EMPTY through every membership-scoped surface, and
# child-scoped claims (a child's own facets) were invisible to it. Found live: the
# web desk, grounded in `hsdl`, ran four empty searches and told a patron the
# collection did not hold a thesis it held.
#
# The fix is for READ surfaces only. Leaves are byte-identical; siblings still never
# see each other (rule 4); tending, planning, pulse and topology stay direct (rule 2).
RSpec.describe "Context read scope (v0.78)" do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  let!(:root)    { Enliterator::Context.create!(key: "fed", name: "Federation") }
  let!(:theses)  { Enliterator::Context.create!(key: "theses", name: "Theses", parent: root) }
  let!(:reports) { Enliterator::Context.create!(key: "reports", name: "Reports", parent: root) }

  def visit!(record, context: nil, facet: "summary")
    record.enliterator_visits.create!(facet: facet, status: "succeeded", applied: true,
                                      tier: "cheap", context: context)
  end

  def claim!(record, key:, value:, context: nil, facet: "summary")
    record.enliterator_claims.create!(key: key, value: value, status: "draft", confidence: 0.8,
                                      context: context, visit: visit!(record, context: context, facet: facet))
  end

  def enliterate!(title, body: "b", **claims)
    w = Widget.create!(title: title, body: body)
    claims.each { |k, v| claim!(w, key: k.to_s, value: v) }
    w.enliterator_embeddings.create!(kind: "primary", embedding: embedder.embed(w.enliterator_text),
                                     dimensions: embedder.dimensions, model: "null")
    w
  end

  def call_tool(name, **args) = Enliterator::Mcp.dispatch(name, args.transform_keys(&:to_s))

  describe "Context#read_scope_ids" do
    it "equals scope_ids for a leaf (byte-identical reads)" do
      expect(theses.read_scope_ids).to eq(theses.scope_ids)
    end

    it "adds every descendant for a parent, and never a sibling" do
      expect(root.read_scope_ids).to contain_exactly(nil, root.id, theses.id, reports.id)
      expect(theses.read_scope_ids).not_to include(reports.id)
    end
  end

  describe "ContextMembership" do
    it "renders the SAME SQL as member_exists for a leaf" do
      direct  = Enliterator::ContextMembership.member_exists(theses, type_sql: "t.a", id_sql: "t.b").to_sql
      subtree = Enliterator::ContextMembership.member_exists_in_subtree(theses, type_sql: "t.a", id_sql: "t.b").to_sql
      expect(subtree).to eq(direct)
    end

    it "counts a record seated in two children once" do
      w = enliterate!("Both")
      w.place_in_context!(theses)
      w.place_in_context!(reports)
      enliterate!("Only").place_in_context!(theses)
      expect(Enliterator::ContextMembership.subtree_member_count(root)).to eq(2)
      expect(Enliterator::ContextMembership.subtree_member_count(theses)).to eq(2)
      expect(root.memberships.count).to eq(0)
    end
  end

  describe "read surfaces at a parent with no direct holdings" do
    let!(:thesis) do
      enliterate!("Stress of Silence", body: "firefighter mayday training").tap do |w|
        w.place_in_context!(theses)
        claim!(w, key: "key_findings", value: "Silence raised recruit stress.", context: theses, facet: "significance")
        claim!(w, key: "advisor", value: "Dr. Voss")
      end
    end
    let!(:report) do
      enliterate!("A Report", body: "appropriations").tap do |w|
        w.place_in_context!(reports)
        claim!(w, key: "policy_area", value: "budget", context: reports, facet: "policy")
      end
    end

    it "Catalog search and subject browse reach the children's members" do
      cat = Enliterator::Catalog.new(context: root, embedder: embedder)
      expect(cat.search("anything")[:records].map { |c| c[:label] }).to contain_exactly("Stress of Silence", "A Report")
      expect(cat.subject("advisor", "Dr. Voss")[:total]).to eq(1)
      expect(cat.subject("key_findings", "Silence raised recruit stress.")[:total]).to eq(1)
    end

    it "a sibling still cannot see a sibling (rule 4)" do
      cat = Enliterator::Catalog.new(context: theses, embedder: embedder)
      expect(cat.search("anything")[:records].map { |c| c[:label] }).to eq([ "Stress of Silence" ])
      expect(cat.subject("policy_area", "budget")[:total]).to eq(0)
    end

    it "record_entry at the parent shows a claim tended in a child context" do
      entry = call_tool("record_entry", type: "Widget", id: thesis.id.to_s, context: "fed")
      keys = entry[:claims].values.flatten.map { |c| c[:key] }
      expect(keys).to include("key_findings", "advisor")
    end

    it "search / browse_subjects / subject_search through MCP answer at the parent" do
      hits = call_tool("search", q: "mayday", context: "fed")[:records].map { |r| r[:label] }
      expect(hits).to include("Stress of Silence")
      expect(call_tool("subject_search", key: "advisor", value: "Dr. Voss", context: "fed")[:records].size).to eq(1)
      expect(call_tool("browse_subjects", context: "fed")[:headings]).not_to be_empty
    end

    it "lacunae at the parent report the children's gaps" do
      Enliterator::Lacuna.create!(tendable: thesis, facet: "significance", key: "methodology",
                                  context_id: theses.id, diagnosis: "silent")
      expect(call_tool("lacunae", context: "fed")[:open_total]).to eq(1)
      expect(call_tool("lacunae", context: "reports")[:open_total]).to eq(0)
    end

    it "collection_overview reports reachable members, and keeps the direct count beside it" do
      tree = call_tool("collection_overview")[:contexts].index_by { |c| c[:key] }
      expect(tree["fed"]).to include(members: 2, direct_members: 0)
      expect(tree["theses"]).to include(members: 1, direct_members: 1)
    end

    it "name authorities seated in a child merge variants in the parent's headings" do
      Enliterator.configuration.name_authority_keys = [ "advisor" ]
      claim!(thesis, key: "advisor", value: "Dr. J. Voss")
      Enliterator::NameAuthority.create!(canonical: "Dr. Voss", variants: [ "Dr. Voss", "Dr. J. Voss" ],
                                         context_id: theses.id, status: "auto")
      advisor = Enliterator::Catalog.new(context: root, embedder: embedder).overview[:headings]
                  .find { |h| h[:key] == "advisor" }
      expect(advisor[:values].map(&:first)).to include("Dr. Voss")
      expect(advisor[:values].map(&:first)).not_to include("Dr. J. Voss")
    ensure
      Enliterator.configuration.name_authority_keys = []
    end
  end

  # The planner, pulse, topology and tending-neighbor specs pin direct semantics and
  # must pass UNCHANGED (heartbeat_plan_spec, heartbeat_pulse*_spec, topology_sync_spec,
  # tending/context_scoped_spec). This file only pins the scope a tend reads.
  describe "tend paths stay direct (rule 2)" do
    it "the tending effective scope for a parent is still its own path, not its subtree" do
      expect(root.scope_ids).to contain_exactly(nil, root.id)
    end
  end
end
