# frozen_string_literal: true

require "rails_helper"

# v0.6 hybrid conversation. Assembles the self-portrait (Synopsis) + embedding
# retrieval of the most relevant tended records' claims, then asks the LLM in
# free-form. Streams deltas via the block; returns provenance. No network.
RSpec.describe Enliterator::Conversation do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # Records the assembled messages and yields canned chunks when streaming.
  class ConvStubLLM
    attr_reader :messages, :tags, :streamed
    def model_id = "stub-quality"
    def converse(messages:, tags: [], stream: false, &block)
      @messages = messages
      @tags     = tags
      @streamed = stream
      canned = [ "Alpha ", "connects ", "to ", "Beta." ]
      canned.each { |c| block.call(c) } if stream && block
      canned.join
    end
  end

  def configure_policy!
    policy = Enliterator::Staffing::Policy.new do
      stream :summary, tier: "cheap", keys: { summary: "An abstract." }
      ladder [ "cheap", "quality" ]
    end
    Enliterator.configure { |c| c.staffing = policy }
  end

  def embed!(rec)
    rec.enliterator_embeddings.create!(
      kind: "primary", embedding: embedder.embed(rec.enliterator_text),
      dimensions: embedder.dimensions, model: "null"
    )
  end

  describe "#reply (hybrid grounding)" do
    let(:stub)  { ConvStubLLM.new }
    let(:alpha) { Widget.create!(title: "Alpha", body: "human trafficking and disaster response") }
    let(:beta)  { Widget.create!(title: "Beta",  body: "human trafficking detection in transport") }

    before do
      configure_policy!
      [ alpha, beta ].each { |w| embed!(w) }
      alpha.enliterator_claims.create!(key: "summary", value: "Alpha is about human trafficking.", status: "draft")
      beta.enliterator_claims.create!(key: "summary",  value: "Beta detects trafficking in transit.", status: "draft")
    end

    subject(:conv) { described_class.new(llm: stub, embedder: embedder) }

    it "grounds the prompt in BOTH the self-portrait and retrieved claims" do
      conv.reply(question: "what about trafficking?")
      system_msg = stub.messages.first[:content]
      user_msg   = stub.messages.last[:content]
      expect(system_msg).to include("COLLECTION SELF-PORTRAIT")
      expect(user_msg).to include("RETRIEVED RECORDS")
      expect(user_msg).to match(/Alpha is about human trafficking\.|Beta detects trafficking/)
    end

    it "cites records by human-readable label (title + author + year), not raw ids" do
      alpha.enliterator_claims.create!(key: "authored_by", value: "Jane Roe", status: "draft")
      alpha.enliterator_claims.create!(key: "publication_year", value: 2024, status: "draft")
      conv.reply(question: "trafficking?")
      user_msg   = stub.messages.last[:content]
      system_msg = stub.messages.first[:content]
      expect(user_msg).to include('"Alpha"').and include("by Jane Roe").and include("(2024)")
      expect(system_msg).to match(/human-readable/i)
      expect(system_msg).to match(/never by a raw internal id/i)
    end

    it "streams deltas in order via the block and returns the full answer" do
      got = []
      prov = conv.reply(question: "link?", stream: true) { |d| got << d }
      expect(got).to eq([ "Alpha ", "connects ", "to ", "Beta." ])
      expect(prov[:answer]).to eq("Alpha connects to Beta.")
      expect(stub.streamed).to be(true)
    end

    it "returns provenance: the retrieved record refs + the tier" do
      prov = conv.reply(question: "trafficking?")
      refs = prov[:records].map { |r| "#{r[:type]}/#{r[:id]}" }
      expect(refs).to include("Widget/#{alpha.id}", "Widget/#{beta.id}")
      expect(prov[:tier]).to eq("stub-quality")
      expect(prov[:degraded]).to be_nil
    end

    it "tags the gateway call for spend attribution" do
      conv.reply(question: "x")
      expect(stub.tags).to include("enliterator", "conversation")
    end
  end

  describe "tier resolution + Null degradation (no injection, no gateway)" do
    before { Enliterator.configuration.allow_null_llm = false } # production-like

    it "resolves Null, flags degraded, returns the canned answer, and does NOT raise" do
      conv = described_class.new(embedder: embedder)
      prov = nil
      expect { prov = conv.reply(question: "anything?") }.not_to raise_error
      expect(prov[:degraded]).to eq("null-llm")
      expect(prov[:answer]).to eq(Enliterator::Adapters::LLM::Null::CANNED_REPLY)
    end
  end
end
