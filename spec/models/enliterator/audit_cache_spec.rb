# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Audit do
  around { |ex| old = Rails.cache; Rails.cache = ActiveSupport::Cache::MemoryStore.new; ex.run; Rails.cache = old }

  it "serves accuracy from cache and invalidates when a new audit is filed" do
    w = Widget.create!(title: "T", body: "b")
    v = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    c = w.enliterator_claims.create!(key: "topic", value: "x", status: "live", visit: v)
    first = described_class.accuracy_cached
    expect(first).to eq(described_class.accuracy_cached)   # second call: same value from cache
    described_class.create!(claim: c, source: "human", auditor: "j", verdict: "supported", rationale: "r")
    expect(described_class.accuracy_cached).not_to eq(first)  # key moved on the write
  end
end
