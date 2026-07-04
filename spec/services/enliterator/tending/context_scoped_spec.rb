# frozen_string_literal: true

require "rails_helper"

# v0.13 — context-scoped tending. Claims write DOWN into the tending context;
# reads (state) come UP the ancestry (root rule: NULL is root); reconcile never
# crosses contexts; neighbors are restricted to the context's members.
RSpec.describe "Enliterator::Tending::Visitor context scoping (v0.13)" do
  let(:root)     { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
  let(:eo_ctx)   { Enliterator::Context.create!(key: "executive-orders", name: "EOs", parent: root) }
  let(:list_ctx) { Enliterator::Context.create!(key: "election-security", name: "Election Security", parent: root) }
  let(:widget)   { Widget.create!(title: "EO 14067", body: "directive text") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # Canned-claims stub honoring the tend kwargs; records what it was handed.
  class CtxStub
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    attr_reader :seen_state, :seen_neighbors, :seen_contract
    def initialize(claims: [], suggestions: []) = (@claims = claims; @suggestions = suggestions)
    def model_id = "model-cheap"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      @seen_state     = state
      @seen_neighbors = neighbors
      @seen_contract  = contract
      Result.new(parsed: { "claims" => @claims, "confidence" => 0.9, "suggestions" => @suggestions }, raw: {}, tokens: {})
    end
  end

  def configure_policy!
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        context "executive-orders" do
          facet :directive, tier: "cheap", terms: { eo_number: "The EO number.", supersedes: "EOs this revokes." }
        end
        context "election-security" do
          facet :significance, tier: "cheap", terms: { relevance: "Why it matters to election security." }
        end
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
  end

  def tend_with!(stub, facet:, context: nil)
    configure_policy!
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
    Enliterator::Tending::Visitor.new(widget, facet: facet, context: context, embedder: embedder).call
  end

  it "writes claims + the visit INTO the tending context; root tends stay NULL" do
    visit = tend_with!(CtxStub.new(claims: [ { "key" => "eo_number", "op" => "ADD", "value" => "14067" } ]),
                       facet: "directive", context: eo_ctx)
    claim = widget.enliterator_claims.live.find_by(key: "eo_number")
    expect(visit.context).to eq(eo_ctx)
    expect(claim.context).to eq(eo_ctx)

    root_visit = tend_with!(CtxStub.new(claims: [ { "key" => "summary", "op" => "ADD", "value" => "x" } ]),
                            facet: "summary")
    expect(root_visit.context_id).to be_nil
    expect(widget.enliterator_claims.live.find_by(key: "summary").context_id).to be_nil
  end

  it "reconcile NEVER crosses contexts: the same key in a sibling context is a different claim" do
    tend_with!(CtxStub.new(claims: [ { "key" => "relevance", "op" => "ADD", "value" => "EO view" } ]),
               facet: "significance", context: list_ctx)
    # Same key tended in the EO context (off-contract there, so use list again with new value
    # via UPDATE — the live claim in list_ctx must be superseded, the sibling's untouched).
    eo_claim = widget.enliterator_claims.create!(key: "relevance", value: "sibling", status: "draft", context: eo_ctx)

    tend_with!(CtxStub.new(claims: [ { "key" => "relevance", "op" => "UPDATE", "value" => "deeper" } ]),
               facet: "significance", context: list_ctx)

    live_list = widget.enliterator_claims.live.where(context: list_ctx, key: "relevance")
    expect(live_list.count).to eq(1)
    expect(live_list.first.value).to eq("deeper")
    expect(eo_claim.reload.status).not_to eq("superseded")   # the sibling's claim untouched
  end

  it "cumulative read (read-up): state includes root + ancestor claims, labeled by context" do
    widget.assert_claim!(key: "publication_year", value: 2022)            # root (NULL)
    widget.enliterator_claims.create!(key: "eo_number", value: "14067", status: "draft", context: eo_ctx)
    stub = CtxStub.new
    tend_with!(stub, facet: "directive", context: eo_ctx)

    keys = stub.seen_state[:claims].map { |c| [ c[:key], c[:context] ] }
    expect(keys).to include([ "publication_year", "root" ], [ "eo_number", "executive-orders" ])
  end

  it "a sibling context's claims are NOT in the state read" do
    widget.enliterator_claims.create!(key: "relevance", value: "list-only", status: "draft", context: list_ctx)
    stub = CtxStub.new
    tend_with!(stub, facet: "directive", context: eo_ctx)
    expect(stub.seen_state[:claims].map { |c| c[:key] }).not_to include("relevance")
  end

  it "neighbors are restricted to the context's MEMBERS (rule 3); root stays corpus-wide" do
    member     = Widget.create!(title: "EO 13800", body: "cyber eo")
    non_member = Widget.create!(title: "A thesis", body: "thesis text")
    [ widget, member, non_member ].each do |w|
      w.enliterator_embeddings.create!(kind: "primary", embedding: embedder.embed(w.title),
                                       dimensions: embedder.dimensions, model: "null")
    end
    member.place_in_context!(eo_ctx)
    widget.place_in_context!(eo_ctx)

    stub = CtxStub.new
    tend_with!(stub, facet: "directive", context: eo_ctx)
    expect(stub.seen_neighbors).to contain_exactly(member)   # non_member excluded despite proximity

    root_stub = CtxStub.new
    tend_with!(root_stub, facet: "summary")
    expect(root_stub.seen_neighbors).to include(non_member)  # corpus-wide at root
  end

  it "the contract handed to the model is the context's own facet vocabulary" do
    stub = CtxStub.new
    tend_with!(stub, facet: "directive", context: eo_ctx)
    expect(stub.seen_contract.keys).to contain_exactly("eo_number", "supersedes")
  end

  # v0.56 — whole-scoped root reading (topology + default_reading_scope :whole):
  # a member's tend-time neighbors come from its OWN whole, resolved
  # GROUPING-DIRECT (the host FK), never from the derived context's membership
  # rows (which could lag or be unseeded). Flags unset ⇒ the root corpus-wide
  # assertion above is the byte-identity proof.
  describe "whole-scoped root reading (v0.56)" do
    let(:book_a)   { Book.create!(slug: "book-a", title: "Book A") }
    let(:book_b)   { Book.create!(slug: "book-b", title: "Book B") }
    let(:sibling)  { Widget.create!(title: "same book",  body: "s", book_id: book_a.id) }
    let(:stranger) { Widget.create!(title: "other book", body: "o", book_id: book_b.id) }

    def declare_whole_scope!
      Enliterator.configure do |c|
        c.topology = Enliterator::Topology.new do
          whole "Book", members: "Widget", foreign_key: :book_id,
                context_key: :slug, context_name: :title
        end
        c.default_reading_scope = :whole
      end
    end

    def embed_all!(*records)
      records.each do |w|
        w.enliterator_embeddings.create!(kind: "primary", embedding: embedder.embed(w.title),
                                         dimensions: embedder.dimensions, model: "null")
      end
    end

    it "a member's root-tend neighbors restrict to same-whole members (grouping-direct — NO membership rows needed)" do
      widget.update!(book_id: book_a.id)
      embed_all!(widget, sibling, stranger)
      declare_whole_scope!
      expect(Enliterator::ContextMembership.count).to eq(0)   # sync never ran — the tend path must not depend on it

      stub = CtxStub.new
      tend_with!(stub, facet: "summary")
      expect(stub.seen_neighbors).to contain_exactly(sibling)
    end

    it "a member with a nil foreign key (no whole) honestly falls back corpus-wide" do
      embed_all!(widget, sibling, stranger)   # widget.book_id stays nil
      declare_whole_scope!

      stub = CtxStub.new
      tend_with!(stub, facet: "summary")
      expect(stub.seen_neighbors).to include(sibling, stranger)
    end

    it "an explicit context: still wins over the whole scope (the lens branch runs first)" do
      widget.update!(book_id: book_a.id)
      embed_all!(widget, sibling, stranger)
      declare_whole_scope!
      stranger.place_in_context!(list_ctx)
      widget.place_in_context!(list_ctx)

      stub = CtxStub.new
      tend_with!(stub, facet: "significance", context: list_ctx)
      expect(stub.seen_neighbors).to contain_exactly(stranger)   # the lens, not the whole
    end

    it "a record whose type has no declaration is untouched by the scope" do
      embed_all!(widget, sibling, stranger)
      Enliterator.configure do |c|
        c.topology = Enliterator::Topology.new do
          whole "Book", members: "SomethingElse", foreign_key: :book_id,
                context_key: :slug, context_name: :title
        end
        c.default_reading_scope = :whole
      end

      stub = CtxStub.new
      tend_with!(stub, facet: "summary")
      expect(stub.seen_neighbors).to include(sibling, stranger)   # corpus-wide
    end
  end
end
