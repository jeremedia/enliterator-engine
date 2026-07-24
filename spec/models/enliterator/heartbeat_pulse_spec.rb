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
end
