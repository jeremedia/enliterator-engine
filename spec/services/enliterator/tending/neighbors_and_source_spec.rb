# frozen_string_literal: true

require "rails_helper"

# v0.4: neighbors carry CONTENT (resolved to records, truncated), and the tend
# text source is stream-aware. These are what unlock real cross-record connection
# claims and title-page-sourced authorship.
RSpec.describe "Enliterator v0.4 neighbor content + stream-aware source" do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def embed!(widget)
    widget.enliterator_embeddings.create!(
      kind: "primary", embedding: embedder.embed(widget.enliterator_text),
      dimensions: embedder.dimensions, model: "null"
    )
  end

  describe "nearest_neighbors resolves to embeddable records" do
    it "returns the neighbor RECORDS (not Embedding rows)" do
      a = Widget.create!(title: "Alpha", body: "human trafficking and disaster response")
      b = Widget.create!(title: "Beta",  body: "human trafficking detection in transport")
      [ a, b ].each { |w| embed!(w) }

      visitor = Enliterator::Tending::Visitor.new(a, stream: "connections", embedder: embedder)
      neighbors = visitor.nearest_neighbors(a, limit: 5)

      expect(neighbors).to all(be_a(Widget))
      expect(neighbors).to include(b)
      expect(neighbors).not_to include(a) # self excluded
    end

    it "returns [] when the record has no primary embedding" do
      a = Widget.create!(title: "NoEmbed", body: "x")
      visitor = Enliterator::Tending::Visitor.new(a, stream: "connections", embedder: embedder)
      expect(visitor.nearest_neighbors(a, limit: 5)).to eq([])
    end
  end

  describe "summarize_neighbors carries truncated record text" do
    it "includes type/id/text and truncates to the snippet bound" do
      w = Widget.create!(title: "T" * 40, body: "B" * 600)
      out = Enliterator::Adapters::LLM::Null.new.send(:summarize_neighbors, [ w ]).first

      expect(out["type"]).to eq("Widget")
      expect(out["id"]).to eq(w.id.to_s)
      expect(out["text"]).to be_present
      expect(out["text"].length).to be <= Enliterator::Adapters::LLM::Base::NEIGHBOR_SNIPPET_CHARS
    end
  end

  describe "enliterator_text is stream-aware" do
    it "passes stream to a stream-aware to_enliterator_text override" do
      w = Widget.create!(title: "t", body: "b")
      def w.to_enliterator_text(stream: nil) = "SOURCE-FOR=#{stream}"
      expect(w.enliterator_text(stream: "authorship")).to eq("SOURCE-FOR=authorship")
    end

    it "falls back to the zero-arg override (back-compat, no crash)" do
      w = Widget.create!(title: "t", body: "b") # Widget#to_enliterator_text takes no args
      expect { w.enliterator_text(stream: "summary") }.not_to raise_error
      expect(w.enliterator_text(stream: "summary")).to eq(w.to_enliterator_text)
    end
  end
end
