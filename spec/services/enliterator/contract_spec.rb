# frozen_string_literal: true

require "rails_helper"

# v0.9 — the effective contract: code keys + curator-approved keys. Byte-identical
# to keys_for when nothing is approved; merges approved-key extensions otherwise.
RSpec.describe Enliterator::Contract do
  let(:w) { Widget.create!(title: "A", body: "x") }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        stream :summary, tier: "cheap", keys: { summary: "An abstract." }
        assign :notes, tier: "cheap"           # unconstrained
        ladder [ "cheap" ]
      end
    end
  end

  it "returns exactly keys_for when nothing is approved (incl. nil for unconstrained)" do
    expect(described_class.for("summary")).to eq("summary" => "An abstract.")
    expect(described_class.for("notes")).to be_nil
    expect(described_class.for("undeclared")).to be_nil
  end

  it "merges approved-key extensions, described from the term's rationale" do
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "keywords", rationale: "r", status: "approved")
    Enliterator::ProposedTerm.create!(proposed_key: "keywords", recommended_rationale: "salient retrieval terms")

    eff = described_class.for("summary")
    expect(eff).to include("summary" => "An abstract.", "keywords" => "salient retrieval terms")
  end

  it "defaults the description when the term has no rationale" do
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "case_studies", rationale: "r", status: "approved")
    expect(described_class.for("summary")["case_studies"]).to eq(Enliterator::Contract::DEFAULT_DESCRIPTION)
  end

  it "lets code-defined keys win on a name conflict" do
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "summary", rationale: "r", status: "approved")
    Enliterator::ProposedTerm.create!(proposed_key: "summary", recommended_rationale: "OVERRIDE")
    expect(described_class.for("summary")["summary"]).to eq("An abstract.") # code wins
  end

  it "ignores approvals when apply_approved_keys is false" do
    Enliterator.configuration.apply_approved_keys = false
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "keywords", rationale: "r", status: "approved")
    expect(described_class.for("summary")).to eq("summary" => "An abstract.")
  end

  it "only counts APPROVED suggestions (pending/mapped/rejected don't extend the contract)" do
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "pending_k", rationale: "r", status: "pending")
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "mapped_k",  rationale: "r", status: "mapped")
    expect(described_class.for("summary").keys).to contain_exactly("summary")
  end
end
