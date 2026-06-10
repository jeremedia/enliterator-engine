require "rails_helper"

# v0.20: the prepared rollups — Synopsis and the conservation report are
# served from Rails.cache, keyed by the latest heartbeat id (each cycle
# republishes) with a short TTL. The suite normally runs on the null store
# (every other spec exercises the uncached path for free); these swap in a
# memory store to pin the caching behavior itself.
RSpec.describe "v0.20 rollup caching" do
  around do |ex|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ex.run
  ensure
    Rails.cache = original
  end

  def beat_row!
    Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 100,
                                   planned: {}, started_at: Time.current)
  end

  describe Enliterator::Synopsis do
    it "assembles once and serves the second read from cache" do
      expect(Enliterator::Synopsis).to receive(:assemble).once.and_call_original
      first  = Enliterator::Synopsis.build
      second = Enliterator::Synopsis.build
      expect(second).to eq(first)
    end

    it "republishes when a new heartbeat cycle lands (the key carries the cycle id)" do
      expect(Enliterator::Synopsis).to receive(:assemble).twice.and_call_original
      Enliterator::Synopsis.build
      beat_row!
      Enliterator::Synopsis.build
    end
  end

  describe Enliterator::Condition do
    it "computes the report once and serves the second read from cache" do
      expect(Enliterator::Condition).to receive(:surveyed_count).once.and_call_original
      first  = Enliterator::Condition.report
      second = Enliterator::Condition.report
      expect(second).to eq(first)
      expect(first.keys).to contain_exactly(:surveyed, :total, :untendable, :piles, :residue_count)
    end

    it "republishes when a new heartbeat cycle lands" do
      expect(Enliterator::Condition).to receive(:surveyed_count).twice.and_call_original
      Enliterator::Condition.report
      beat_row!
      Enliterator::Condition.report
    end
  end
end
