# frozen_string_literal: true

require "rails_helper"

# v-next — the directed pulse: a definable, targeted heartbeat.
RSpec.describe "Enliterator::Heartbeat directed pulse (v-next)" do
  describe "the trigger column" do
    it "defaults to 'scheduled' on a plain row" do
      row = Enliterator::Heartbeat.create!(started_at: Time.current, mode: "sync")
      expect(row.trigger).to eq("scheduled")
    end
  end

  describe "config hooks" do
    it "default to nil" do
      expect(Enliterator.configuration.pulse_resolver).to be_nil
      expect(Enliterator.configuration.pulse_synthesis).to be_nil
    end
  end

  describe ".open! plan injection" do
    # A minimal plan with zero items — enough to exercise the seam without an LLM.
    def empty_plan
      Enliterator::Heartbeat::Plan.new(
        budget: 5_000, change_cap: 0, items: [], warnings: [],
        frontier_remaining: {}, horizon_tokens: 0
      )
    end

    it "uses the injected plan and stamps trigger 'pulse'" do
      row, the_plan = Enliterator::Heartbeat.open!(plan: empty_plan)
      expect(the_plan.budget).to eq(5_000)
      expect(row.trigger).to eq("pulse")
      expect(row.budget_tokens).to eq(5_000)
    end

    it "computes the change-envelope plan and stamps 'scheduled' when no plan is injected" do
      row, _plan = Enliterator::Heartbeat.open!
      expect(row.trigger).to eq("scheduled")
    ensure
      row&.update!(finished_at: Time.current) # release the overlap lock for later examples
    end
  end

  describe ".pulse" do
    let(:book) { Enliterator::Context.create!(key: "the-smaller-infinity", name: "TSI") }

    class PulseStubLLM
      Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
      attr_reader :tend_calls
      def initialize = (@tend_calls = 0)
      def model_id = "model-cheap"
      def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
        @tend_calls += 1
        Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {},
                   tokens: { "input" => 50, "output" => 50, "total" => 100 })
      end
      def decide(messages:, schema:, tool_name:, tags: []) = { "recommendations" => [] }
    end

    def one_facet_policy!
      Enliterator.configure do |c|
        c.tending_facets = []
        c.staffing = Enliterator::Staffing::Policy.new do
          context "the-smaller-infinity" do
            facet :significance, tier: "cheap", terms: { note: "A note." }
          end
          ladder [ "cheap" ]
          verify_floor "cheap"
        end
      end
    end

    def stale_member!(title)
      w = Widget.create!(title: title, body: "b")
      w.place_in_context!(book)
      Enliterator::Visit.create!(tendable: w, facet: "significance", context: book,
                                 tier: "cheap", status: "succeeded", applied: true,
                                 started_at: 5.days.ago)
      w.update_columns(updated_at: 1.day.ago) # edited after the tend ⇒ stale
      w
    end

    let(:stub_llm) { PulseStubLLM.new }

    # Enqueue-mode examples (added later) enqueue TendingVisitJobs; the dummy's
    # default :async adapter would run them on another thread — invoking the
    # rspec-mocks partial double off the example thread (not thread-safe) and
    # writing Visits past the rollback window. Pin the :test adapter (enqueue-only),
    # the beat spec's idiom. This is plain ActiveJob state (not Enliterator config,
    # not a mock), so an around pre-block is safe here — the global reset doesn't
    # touch it.
    around do |ex|
      old = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      ex.run
      ActiveJob::Base.queue_adapter = old
    end

    # BOTH the policy and the LLM stub live in `before`, never an `around` pre-block.
    # Two ordering traps this avoids: (1) the suite's global
    # `config.before(:each) { Enliterator.reset_configuration! }` (rails_helper) runs
    # INSIDE example.run, so config set in an around pre-block is wiped before the
    # body — a group before(:each) runs AFTER the global reset and survives; (2)
    # rspec-mocks isn't live until inside example.run, so `allow(...)` in an around
    # pre-block raises OutsideOfExampleError. (The beat spec configures inside each it.)
    before do
      one_facet_policy!
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub_llm)
    end

    it "tends the stale targets, stamps trigger + reason, records a ledger row" do
      w = stale_member!("combustion-edge")
      row = Enliterator::Heartbeat.pulse(stale: true, context: "the-smaller-infinity")
      expect(row).to be_finished
      expect(row.trigger).to eq("pulse")
      expect(stub_llm.tend_calls).to eq(1)
      visit = Enliterator::Visit.where(tendable: w, heartbeat_id: row.id).last
      expect(visit.reason).to eq("pulse")
    end

    it "is a LOUD no-op for an existing, empty context — opens no row" do
      book # the context exists but has no members ⇒ nothing resolves
      expect(Enliterator::Heartbeat.pulse(stale: true, context: "the-smaller-infinity")).to be_nil
      expect(Enliterator::Heartbeat.count).to eq(0)
    end
  end
end
