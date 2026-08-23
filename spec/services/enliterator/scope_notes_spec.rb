# frozen_string_literal: true

require "rails_helper"

# v0.74 — SKOS scope notes: terms that say what they are NOT (exclusions) and
# when they apply at all (preconditions). Split at Policy ingest so term_lists
# stays {key => String} forever; ONE source (Vocabulary.scope_notes_for) feeds
# reader AND examiner, so they cannot silently disagree about what a term means.
RSpec.describe "v0.74 scope notes" do
  def policy(&block) = Enliterator::Staffing::Policy.new(&block)

  RICH = {
    supersedes: { scope: "Prior orders this document changes.",
                  not: [ "orders the document explicitly preserves or continues" ],
                  applies_only_when: "the document actually changes a prior order" },
    implements: { scope: "What this document operationalizes.",
                  not: [ "establishing a body or program (establishes != implements)" ] },
    citation:   "Plain string term."
  }.freeze

  describe "Policy ingest (the split)" do
    let(:p) do
      policy do
        facet :legal_relations, tier: "cheap", terms: RICH
        ladder [ "cheap" ]
      end
    end

    it "keeps term_lists {key => String} forever — the scope string, never a Hash" do
      terms = p.terms_for("legal_relations")
      expect(terms.values).to all(be_a(String))
      expect(terms["supersedes"]).to eq("Prior orders this document changes.")
      expect(terms["citation"]).to eq("Plain string term.")
    end

    it "routes not/applies_only_when into scope_notes_for" do
      notes = p.scope_notes_for("legal_relations")
      expect(notes["supersedes"]).to eq(
        "not" => [ "orders the document explicitly preserves or continues" ],
        "applies_only_when" => "the document actually changes a prior order"
      )
      expect(notes["implements"]).to eq("not" => [ "establishing a body or program (establishes != implements)" ])
      expect(notes).not_to have_key("citation")
    end

    it "plain-string declarations produce NO scope_notes entry — byte-identical storage" do
      plain = policy do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
      expect(plain.scope_notes_for("summary")).to be_nil
    end

    it "FORBIDS required x applies_only_when on one key at ingest — contradictory instructions" do
      expect {
        policy do
          facet :legal_relations, tier: "cheap", required: [ :supersedes ], terms: RICH
          ladder [ "cheap" ]
        end
      }.to raise_error(Enliterator::ConfigurationError, /applies_only_when/)
    end

    it "resolves descendant-first along the context path, like terms_for" do
      p2 = policy do
        facet :legal_relations, tier: "cheap", terms: RICH
        context "eo" do
          facet :legal_relations, tier: "cheap",
                terms: { supersedes: { scope: "EO-specific.", not: [ "context-specific exclusion" ] } }
        end
        ladder [ "cheap" ]
      end
      expect(p2.scope_notes_for("legal_relations", path: [ "eo" ]).dig("supersedes", "not"))
        .to eq([ "context-specific exclusion" ])
      expect(p2.scope_notes_for("legal_relations").dig("supersedes", "not"))
        .to eq([ "orders the document explicitly preserves or continues" ])
    end
  end

  describe "the reader prompt (Base#system_for)" do
    let(:adapter_class) { Enliterator::Adapters::LLM::Gateway }
    let(:adapter) { adapter_class.allocate }
    let(:contract) { { "supersedes" => "Prior orders this document changes.", "citation" => "Refs." } }
    let(:notes) do
      { "supersedes" => { "not" => [ "orders it explicitly preserves" ],
                          "applies_only_when" => "the document changes a prior order" } }
    end

    it "GOLDEN: scope_notes nil produces the byte-identical v0.73 prompt" do
      expect(adapter.send(:system_for, contract, scope_notes: nil))
        .to eq(adapter.send(:system_for, contract))
    end

    it "renders the precondition and exclusions UNDER the term's contract line" do
      out = adapter.send(:system_for, contract, scope_notes: notes)
      expect(out).to include("APPLIES ONLY WHEN: the document changes a prior order")
      expect(out).to include("emit NO claim for this key")
      expect(out).to include("NOT: orders it explicitly preserves")
      # attached to supersedes' line, before citation's
      expect(out.index("APPLIES ONLY WHEN")).to be < out.index("- citation:")
    end
  end

  describe "the examiner (same notes, same source)" do
    class ScopeNoteExaminerStub
      attr_reader :last_messages
      def model_id = "stub"
      def decide(messages:, schema:, tool_name:, tags: [])
        @last_messages = messages
        { "verdict" => "supported", "rationale" => "r", "confidence" => 0.9 }
      end
    end

    around do |ex|
      prior = Enliterator.configuration.staffing
      ex.run
      Enliterator.configuration.staffing = prior
    end

    def verdict!(stub)
      Enliterator::Audit::Examiner.new(llm: stub).verdict_for(
        facet: "legal_relations", key: "supersedes", value: "EO 1", source: "text",
        truncated: false
      )
    end

    it "extends the KEY MEANING with the notes the reader was given" do
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :legal_relations, tier: "cheap", terms: RICH
          ladder [ "cheap" ]
        end
      end
      stub = ScopeNoteExaminerStub.new
      verdict!(stub)
      user = stub.last_messages.last[:content]
      expect(user).to include("KEY APPLIES ONLY WHEN: the document actually changes a prior order")
      expect(user).to include("KEY EXCLUDES: orders the document explicitly preserves or continues")
    end

    it "GOLDEN: without notes the examiner prompt is byte-identical" do
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :legal_relations, tier: "cheap",
                terms: { supersedes: "Prior orders this document changes." }
          ladder [ "cheap" ]
        end
      end
      stub = ScopeNoteExaminerStub.new
      verdict!(stub)
      expect(stub.last_messages.last[:content]).not_to include("KEY APPLIES ONLY WHEN", "KEY EXCLUDES")
    end
  end

  describe "the visitor threads them (and the resolved-path backstop)" do
    class ScopeNoteReaderStub
      Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
      attr_reader :seen_notes, :seen_required
      def model_id = "stub"
      def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil, scope_notes: nil)
        @seen_notes    = scope_notes
        @seen_required = required
        Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {}, tokens: {})
      end
    end

    let(:widget)   { Widget.create!(title: "T", body: "b") }
    let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

    around do |ex|
      prior = Enliterator.configuration.staffing
      ex.run
      Enliterator.configuration.staffing = prior
    end

    def tend_with!(stub)
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
      Enliterator::Tending::Visitor.new(widget, facet: "legal_relations", embedder: embedder).call
    end

    it "hands the resolved notes to the adapter (probed kwarg)" do
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :legal_relations, tier: "cheap", terms: RICH
          ladder [ "cheap" ]
          verify_floor "cheap"
        end
      end
      stub = ScopeNoteReaderStub.new
      tend_with!(stub)
      expect(stub.seen_notes.dig("supersedes", "applies_only_when"))
        .to eq("the document actually changes a prior order")
    end

    it "BACKSTOP: a cross-context required x precondition drops the precondition, keeps exclusions" do
      # root declares supersedes REQUIRED (plain terms); the context redeclares
      # the facet with a precondition but WITHOUT required: — required falls
      # through to root while scope notes read descendant-first: both would
      # ship. The backstop drops the precondition (required wins); the
      # exclusion survives (it contradicts nothing).
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :legal_relations, tier: "cheap", required: [ :supersedes ],
                terms: { supersedes: "Prior orders changed." }
          context "eo" do
            facet :legal_relations, tier: "cheap",
                  terms: { supersedes: { scope: "EO-specific.",
                                         not: [ "mere citations" ],
                                         applies_only_when: "the document changes a prior order" } }
          end
          ladder [ "cheap" ]
          verify_floor "cheap"
        end
      end
      ctx = Enliterator::Context.create!(key: "eo", name: "EOs")
      stub = ScopeNoteReaderStub.new
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
      Enliterator::Tending::Visitor.new(widget, facet: "legal_relations",
                                        context: ctx, embedder: embedder).call

      expect(stub.seen_required).to include("supersedes")                     # the obligation shipped
      expect(stub.seen_notes.dig("supersedes", "applies_only_when")).to be_nil # precondition dropped
      expect(stub.seen_notes.dig("supersedes", "not")).to eq([ "mere citations" ])
    end
  end
end
