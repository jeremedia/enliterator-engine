# frozen_string_literal: true

require "rails_helper"

# v0.15 — beat!: the ledger lifecycle. The row opens at start (the overlap
# lock), the plan executes under the budget (sync = enforced on ACTUAL
# tokens), the considerer closes the metabolic cycle, and finalize records
# everything — including the abort path.
RSpec.describe "Enliterator::Heartbeat.beat! (v0.15)" do
  let(:root) { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
  let(:crs)  { Enliterator::Context.create!(key: "crs-reports", name: "CRS", parent: root) }

  # One lane only (no root facets) so item counts are exactly predictable.
  def configure!(llm)
    Enliterator.configure do |c|
      c.tending_facets = []
      c.staffing = Enliterator::Staffing::Policy.new do
        context "crs-reports" do
          facet :policy_analysis, tier: "cheap", terms: { issue_for_congress: "The issue." }
        end
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(llm)
  end

  # Tends cost `cost` ACTUAL tokens each; raises for records titled "boom".
  # Also answers the considerer's decide (no recommendations).
  class BeatStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    attr_reader :tend_calls, :decide_calls

    def initialize(cost: 100)
      @cost = cost
      @tend_calls = 0
      @decide_calls = 0
    end

    def model_id = "model-cheap"

    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      raise "boom" if text.include?("boom")
      @tend_calls += 1
      Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {},
                 tokens: { "input" => @cost / 2, "output" => @cost / 2, "total" => @cost })
    end

    def decide(messages:, schema:, tool_name:, tags: [])
      @decide_calls += 1
      { "recommendations" => [] }
    end
  end

  def widget!(title = "w", context: crs)
    w = Widget.create!(title: title, body: "b")
    w.update_columns(created_at: 90.days.ago, updated_at: 90.days.ago)
    w.place_in_context!(context)
    w
  end

  # Token history so the planner estimates ~100/item instead of the 4K default.
  def seed_history!
    w = widget!("hist")
    w.enliterator_visits.create!(
      facet: "policy_analysis", context: crs, status: "succeeded", applied: true, tier: "cheap",
      tokens: { "input" => 50, "output" => 50, "total" => 100 },
      created_at: 40.days.ago, updated_at: 40.days.ago,
      started_at: 40.days.ago, finished_at: 40.days.ago + 5.seconds
    )
    w
  end

  describe "the ledger lifecycle (sync)" do
    it "opens, executes, considers, finalizes — with actuals on the books" do
      configure!(BeatStubLLM.new(cost: 100))
      seed_history!
      2.times { |i| widget!("w#{i}") }

      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)

      expect(row).to be_finished
      expect(row.mode).to eq("sync")
      expect(row.budget_tokens).to eq(10_000)
      expect(row.planned.dig("counts", "frontier")).to eq(2)
      expect(row.executed.dig("frontier", "succeeded")).to eq(2)
      expect(row.tokens_spent["total"]).to eq(200)
      expect(row.config_snapshot).to include("heartbeat_change_share", "stale_after_seconds")
      expect(row.visits.count).to eq(2)
      expect(row.visits.pluck(:reason).uniq).to eq([ "frontier" ])
      expect(row.error).to be_nil
    end

    it "enforces the budget on ACTUAL tokens and defers the rest, loudly" do
      configure!(BeatStubLLM.new(cost: 300))      # estimates say 100; reality says 300
      seed_history!
      5.times { |i| widget!("w#{i}") }

      row = Enliterator::Heartbeat.beat!(budget: 1_000, skip_consider: true)

      expect(row.executed.dig("frontier", "succeeded")).to eq(4)   # 4×300 = 1200 ≥ 1000 → stop
      expect(row.tokens_spent["total"]).to eq(1_200)
      expect(row.warnings.join).to include("budget reached on actuals")
    end

    it "an item failure logs, counts, and the cycle continues" do
      configure!(BeatStubLLM.new)
      seed_history!
      widget!("ok-1")
      widget!("boom")
      widget!("ok-2")

      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)

      expect(row.executed.dig("frontier", "succeeded")).to eq(2)
      expect(row.executed.dig("frontier", "failed")).to eq(1)
      expect(row.error).to be_nil
      expect(row).to be_finished
    end

    it "aborts as a misconfiguration when the first items ALL fail — error on the row, re-raised" do
      configure!(BeatStubLLM.new)
      seed_history!
      6.times { |i| widget!("boom-#{i}") }

      expect {
        Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      }.to raise_error(/all failed/)

      row = Enliterator::Heartbeat.order(:id).last
      expect(row).to be_finished
      expect(row.error).to match(/all failed/)
      expect(row.executed.dig("frontier", "failed")).to eq(5)
    end

    it "skips (and names) a record that vanished between plan and execution" do
      configure!(BeatStubLLM.new)
      seed_history!
      ghost = widget!("ghost")
      ghost.delete   # raw delete: membership row survives, the record doesn't

      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      expect(row.executed.dig("frontier", "skipped")).to eq(1)
      expect(row.warnings.join).to include("Widget/#{ghost.id} missing")
    end
  end

  describe "the overlap lock" do
    it "refuses while an unfinished cycle is inside the window; force overrides and says so" do
      configure!(BeatStubLLM.new)
      open = Enliterator::Heartbeat.create!(started_at: 1.hour.ago, mode: "sync", budget_tokens: 1)

      expect { Enliterator::Heartbeat.beat! }.to raise_error(Enliterator::Heartbeat::Overlap, /##{open.id}/)

      row = Enliterator::Heartbeat.beat!(force: true, skip_consider: true)
      expect(row.warnings.join).to include("forced past open heartbeat ##{open.id}")
    end

    it "an open row OLDER than the window is crash evidence, not a lock" do
      configure!(BeatStubLLM.new)
      Enliterator::Heartbeat.create!(started_at: 7.hours.ago, mode: "sync", budget_tokens: 1)
      expect { Enliterator::Heartbeat.beat!(skip_consider: true) }.not_to raise_error
    end
  end

  describe "the considerer pass (tend → consider, one metabolic cycle)" do
    it "runs once per scope with open requests and records the outcome" do
      llm = BeatStubLLM.new
      configure!(llm)
      w = seed_history!
      Enliterator::Suggestion.create!(tendable: w, facet: "policy_analysis", context: crs,
                                      proposed_key: "affected_states", status: "pending")

      row = Enliterator::Heartbeat.beat!(budget: 10_000)
      expect(llm.decide_calls).to eq(1)
      expect(row.considerer.keys).to eq([ "crs-reports" ])
      expect(row.considerer["crs-reports"]).to include("considered" => 1)
    end

    it "skip_consider leaves governance untouched" do
      llm = BeatStubLLM.new
      configure!(llm)
      w = seed_history!
      Enliterator::Suggestion.create!(tendable: w, facet: "policy_analysis", context: crs,
                                      proposed_key: "affected_states", status: "pending")

      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      expect(llm.decide_calls).to eq(0)
      expect(row.considerer).to eq({})
    end
  end

  describe "enqueue mode" do
    around do |example|
      old = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
    ensure
      ActiveJob::Base.queue_adapter = old
    end

    it "enqueues TendingVisitJobs carrying context + cycle provenance; actuals stay derivable" do
      configure!(BeatStubLLM.new)
      seed_history!
      w = widget!("w0")

      row = nil
      expect {
        row = Enliterator::Heartbeat.beat!(execute: :enqueue, budget: 10_000, skip_consider: true)
      }.to have_enqueued_job(Enliterator::TendingVisitJob)
        .with(w, "policy_analysis", crs, heartbeat_id: anything, reason: "frontier")

      expect(row.executed.dig("frontier", "enqueued")).to eq(1)
      expect(row.tokens_spent["note"]).to include("derive via Visit.where")
    end

    it "flags a drain deficit when the previous enqueue cycle's jobs never landed" do
      configure!(BeatStubLLM.new)
      seed_history!
      3.times { |i| widget!("w#{i}") }

      first = Enliterator::Heartbeat.beat!(execute: :enqueue, budget: 10_000, skip_consider: true)
      expect(first.executed.dig("frontier", "enqueued")).to eq(3)
      # The jobs never run (test adapter) — no visits land for cycle 1.

      second = Enliterator::Heartbeat.beat!(execute: :enqueue, budget: 10_000, skip_consider: true)
      expect(second.warnings.join).to include("drain deficit")
      expect(second.warnings.join).to include("##{first.id}")
    end
  end
end
