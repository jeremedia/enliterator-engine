# frozen_string_literal: true

require "rails_helper"

# v0.6 collection self-portrait. Pure-read aggregation over Visits/Claims + the
# staffing contracts. tended_count comes from Visits (Claim has no facet column);
# vocabulary comes from the contract; connections from connection-facet keys.
RSpec.describe Enliterator::Synopsis do
  let(:alpha) { Widget.create!(title: "Alpha", body: "alpha body") }
  let(:beta)  { Widget.create!(title: "Beta",  body: "beta body") }

  def configure_policy!
    policy = Enliterator::Staffing::Policy.new do
      facet :summary,     tier: "cheap", terms: { summary: "An abstract." }
      facet :connections, tier: "cheap", terms: { related_records: "Linked records.", thematic_cluster: "The theme." }
      ladder [ "cheap", "quality" ]
    end
    Enliterator.configure { |c| c.staffing = policy }
  end

  def visit!(rec, facet)
    rec.enliterator_visits.create!(facet: facet, status: "succeeded", applied: true)
  end

  def claim!(rec, key, value, status: "draft")
    rec.enliterator_claims.create!(key: key, value: value, status: status)
  end

  before do
    configure_policy!
    visit!(alpha, "summary"); visit!(beta, "summary")
    claim!(alpha, "summary", "Alpha is about X.")
    claim!(beta,  "summary", "Beta is about Y.")
    visit!(alpha, "connections")
    claim!(alpha, "related_records", [ "Beta" ])
    claim!(alpha, "thematic_cluster", "disaster response")
  end

  describe ".build" do
    subject(:syn) { described_class.build(sample_cap: 2, value_chars: 40) }

    it "counts DISTINCT tended records per facet (from Visits)" do
      expect(syn[:facets].find { |s| s[:facet] == "summary" }[:tended_count]).to eq(2)
      expect(syn[:facets].find { |s| s[:facet] == "connections" }[:tended_count]).to eq(1)
    end

    it "reports vocabulary with live-claim counts, descriptions, and samples" do
      vocab = syn[:facets].find { |s| s[:facet] == "summary" }[:vocabulary].find { |v| v[:key] == "summary" }
      expect(vocab[:live_claims]).to eq(2)
      expect(vocab[:description]).to eq("An abstract.")
      expect(vocab[:samples]).to include("Alpha is about X.")
      expect(vocab[:samples].size).to be <= 2
    end

    it "surfaces the connection graph from connection-facet keys" do
      keys = syn[:connections].map { |c| c[:key] }
      expect(keys).to include("related_records", "thematic_cluster")
      expect(syn[:connections].find { |c| c[:key] == "related_records" }[:live_claims]).to eq(1)
    end

    it "includes Report health verbatim and the tendable models" do
      expect(syn[:health]).to eq(Enliterator::Report.summary)
      expect(syn[:models]).to include("Widget")
    end

    it "truncates long sample values to the cap" do
      claim!(alpha, "summary", "z" * 200)
      vocab = described_class.build(value_chars: 40)[:facets]
                .find { |s| s[:facet] == "summary" }[:vocabulary].find { |v| v[:key] == "summary" }
      expect(vocab[:samples].map(&:length).max).to be <= 41 # 40 + ellipsis
    end
  end

  describe ".to_prompt" do
    it "renders compact, bounded text with facets and connections" do
      text = described_class.to_prompt(described_class.build)
      expect(text).to include("COLLECTION SELF-PORTRAIT")
      expect(text).to include('Facet "summary"')
      expect(text).to include("related_records")
      expect(text).to match(/records tended/)
    end
  end
end
