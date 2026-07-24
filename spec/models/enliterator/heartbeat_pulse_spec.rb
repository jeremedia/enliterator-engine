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
end
