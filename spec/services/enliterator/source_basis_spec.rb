# frozen_string_literal: true

require "rails_helper"

# v0.82 — WHOSE WORDS ARE THESE. A located quote is evidence of what the
# document says only when the text it was found in is the document's own.
# The quote tool now reports the basis of the span, and `verbatim` (v0.79)
# turns false when the span sits in model-written text: the deep-read
# notebook (the catalog's own reading notes) or a host-declared AI summary.
RSpec.describe "v0.82 source basis" do
  let(:notebook_line) { "argument: redundant tabulation systems carry the count" }

  def call_tool(name, **args) = Enliterator::Mcp.dispatch(name, args.transform_keys(&:to_s))

  # A host that DECLARES its tending-text composition. Segments are read from
  # an ivar so each example sets its own; the tending text is their join, as
  # the contract requires.
  let(:declaring_host) do
    Class.new(Widget) do
      def self.name = "Widget"
      attr_accessor :declared
      def enliterator_text_segments(facet:) = declared
    end
  end

  def claim_on(record, key:, value:, facet: "summary")
    visit = record.enliterator_visits.create!(facet: facet, status: "succeeded", applied: true, tier: "cheap")
    record.enliterator_claims.create!(key: key, value: value, status: "draft", confidence: 0.8, visit: visit)
  end

  around do |ex|
    prior = Enliterator.configuration.chat_attribution
    ex.run
    Enliterator.configuration.chat_attribution = prior
  end

  describe "Enliterator::SourceBasis.at" do
    let(:widget) { Widget.create!(title: "T", body: "b") }

    it "a Part's text is a section of the source — document_section" do
      part = Enliterator::Part.create!(record: widget, ordinal: 0, heading: "Method", text: "x",
                                       content_digest: "d", char_start: 0, char_end: 1)
      expect(Enliterator::SourceBasis.at(part, facet: "analysis", source: "x", at: 0)).to eq("document_section")
    end

    it "an undeclared host: text before the engine's notebook is undeclared, inside it is reading_notes" do
      source = "Title\n\nAbstract text.\n\n#{Enliterator::Part::NOTEBOOK_HEADER}\n\n## Method\n#{notebook_line}"
      notes_at = source.index(notebook_line)
      expect(Enliterator::SourceBasis.at(widget, facet: "summary", source: source, at: 3)).to eq("undeclared")
      expect(Enliterator::SourceBasis.at(widget, facet: "summary", source: source, at: notes_at)).to eq("reading_notes")
    end

    it "a declared host maps the span to the segment it falls in" do
      host = declaring_host.new(title: "T", body: "b")
      host.declared = [ { text: "Title", basis: "catalog_record" },
                        { text: "The abstract.", basis: "catalog_record" },
                        { text: "An AI summary of it.", basis: "ai_summary" } ]
      source = host.declared.map { |s| s[:text] }.join("\n\n")

      expect(Enliterator::SourceBasis.at(host, facet: "summary", source: source, at: 0)).to eq("catalog_record")
      expect(Enliterator::SourceBasis.at(host, facet: "summary", source: source,
                                         at: source.index("AI summary"))).to eq("ai_summary")
    end

    it "IGNORES a declaration that does not reproduce the tending text — never trusted on faith" do
      host = declaring_host.new(title: "T", body: "b")
      host.declared = [ { text: "something else entirely", basis: "document_text" } ]
      expect(Enliterator::SourceBasis.at(host, facet: "summary", source: "Title\n\nb", at: 0)).to eq("undeclared")
    end

    it "an unknown basis name degrades to undeclared, not to a trusted basis" do
      host = declaring_host.new(title: "T", body: "b")
      host.declared = [ { text: "Title", basis: "gospel" } ]
      expect(Enliterator::SourceBasis.at(host, facet: "summary", source: "Title", at: 0)).to eq("undeclared")
    end
  end

  describe "the quote tool" do
    it "names the basis and marks a span in the reading notes as NOT verbatim" do
      Enliterator.configuration.chat_attribution = true
      notebook = "#{Enliterator::Part::NOTEBOOK_HEADER}\n\n## Method\n#{notebook_line}"
      w = Widget.create!(title: "Thesis", body: notebook)
      claim = claim_on(w, key: "key_findings", value: "redundant tabulation systems carry the count")

      out = call_tool("quote", claim_id: claim.id)
      expect(out[:located]).to be(true)
      expect(out[:basis]).to eq("reading_notes")
      expect(out[:model_written]).to be(true)
      expect(out[:verbatim]).to be(false)   # the catalog's words, not the author's
    end

    it "a span in a host-declared AI summary is model-written" do
      Enliterator.configuration.chat_attribution = true
      w = Widget.create!(title: "Thesis", body: "A machine summary says the count was redundant.")
      claim = claim_on(w, key: "summary", value: "the count was redundant")
      # The quote tool loads the claim's record itself; hand it a declaring
      # host for that record (same row, the declared composition on top).
      host = declaring_host.find(w.id)
      host.declared = [ { text: "Thesis", basis: "catalog_record" },
                        { text: "A machine summary says the count was redundant.", basis: "ai_summary" } ]
      allow(host).to receive(:enliterator_text).and_return(host.declared.map { |s| s[:text] }.join("\n\n"))
      allow_any_instance_of(Enliterator::Claim).to receive(:tendable).and_return(host)

      out = call_tool("quote", claim_id: claim.id)
      expect(out[:basis]).to eq("ai_summary")
      expect(out[:verbatim]).to be(false)
    end

    it "a part claim's span is document_section and stays verbatim" do
      Enliterator.configuration.chat_attribution = true
      w = Widget.create!(title: "Thesis", body: "b")
      part = Enliterator::Part.create!(record: w, ordinal: 0, heading: "Findings",
                                       text: "Clerks kept counting through redundant tabulation.",
                                       content_digest: "d", char_start: 0, char_end: 51)
      claim = claim_on(part, key: "findings", value: "Clerks kept counting through redundant tabulation.",
                             facet: "analysis")

      out = call_tool("quote", claim_id: claim.id)
      expect(out[:basis]).to eq("document_section")
      expect(out[:verbatim]).to be(true)
    end

    it "an undeclared host with no notebook keeps the v0.79 verbatim behavior" do
      Enliterator.configuration.chat_attribution = true
      w = Widget.create!(title: "Thesis", body: "Clerks kept counting through redundant tabulation.")
      claim = claim_on(w, key: "finding", value: "counting through redundant tabulation")

      out = call_tool("quote", claim_id: claim.id)
      expect(out[:basis]).to eq("undeclared")
      expect(out[:verbatim]).to be(true)
    end

    it "flag-off shape gains basis + model_written, nothing renamed" do
      w = Widget.create!(title: "Thesis", body: "Clerks kept counting.")
      claim = claim_on(w, key: "finding", value: "Clerks kept counting")
      out = call_tool("quote", claim_id: claim.id)
      expect(out.keys).to include(:claim, :passage, :located, :basis, :model_written)
      expect(out.keys).not_to include(:verbatim, :source_passage)
    end
  end
end
