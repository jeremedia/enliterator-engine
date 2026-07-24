# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Enliterator::Heartbeat::Pulse.resolve (v-next)" do
  describe "Planner#estimate" do
    it "returns a positive per-facet token estimate" do
      est = Enliterator::Heartbeat::Planner.new.estimate("summary")
      expect(est).to be_a(Integer)
      expect(est).to be > 0
    end
  end
end
