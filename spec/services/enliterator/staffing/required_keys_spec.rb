# frozen_string_literal: true

require "rails_helper"

# v0.5: a facet may declare a subset of its contract keys as REQUIRED. This spec
# pins the Policy storage/reader; the escalation behavior lives in
# spec/services/enliterator/tending/required_terms_spec.rb.
RSpec.describe Enliterator::Staffing::Policy, "required keys (v0.5)" do
  it "stores required keys and leaves the contract hash pristine" do
    policy = described_class.new do
      facet :authorship, tier: "cheap",
             terms: { authored_by: "The author(s).", advisor: "The advisor(s)." },
             required: [ :authored_by ]
    end

    expect(policy.required_terms("authorship")).to eq([ "authored_by" ])
    expect(policy.allowed_terms("authorship")).to match_array(%w[authored_by advisor])
    # required must NOT bleed into the contract descriptions (the Visitor passes
    # this hash to the adapter verbatim; a contract spec asserts it exactly).
    expect(policy.terms_for("authorship")).to eq(
      "authored_by" => "The author(s).", "advisor" => "The advisor(s)."
    )
  end

  it "returns nil when a facet declares no required keys" do
    policy = described_class.new do
      facet :summary, tier: "cheap", terms: { summary: "One abstract." }
      assign :notes, tier: "cheap"
    end

    expect(policy.required_terms("summary")).to be_nil      # keys-only, no required
    expect(policy.required_terms("notes")).to be_nil        # plain assign
    expect(policy.required_terms("undeclared")).to be_nil   # never declared
  end

  it "normalizes required keys to strings and drops blanks" do
    policy = described_class.new do
      facet :authorship, tier: "cheap", terms: { authored_by: "a" },
             required: [ :authored_by, "", nil ]
    end

    expect(policy.required_terms("authorship")).to eq([ "authored_by" ])
  end
end
