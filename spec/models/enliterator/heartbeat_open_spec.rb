# frozen_string_literal: true

require "rails_helper"

# v0.16 — open! (the synchronous half the trigger page calls) and
# execute_async! (the background-thread half). beat! = open! + execute! is
# covered by heartbeat_beat_spec; these pin the new seams.
RSpec.describe "Enliterator::Heartbeat.open! / #execute_async! (v0.16)" do
  describe ".open!" do
    it "creates the row with the plan on it and returns [row, plan]" do
      row, plan = Enliterator::Heartbeat.open!(budget: 5_000)
      expect(row).to be_persisted
      expect(row.finished_at).to be_nil
      expect(row.mode).to eq("sync")
      expect(row.budget_tokens).to eq(5_000)
      expect(row.planned).to include("counts")
      expect(plan).to respond_to(:items)
    end

    it "validates mode first and carries it onto the row (enqueue back-compat)" do
      expect { Enliterator::Heartbeat.open!(mode: :nonsense) }.to raise_error(ArgumentError)
      row, = Enliterator::Heartbeat.open!(mode: :enqueue)
      expect(row.mode).to eq("enqueue")
    end

    it "raises Overlap synchronously — before any row exists — and force records the override" do
      blocking = Enliterator::Heartbeat.create!(started_at: 1.hour.ago, mode: "sync", budget_tokens: 1)

      expect { Enliterator::Heartbeat.open! }.to raise_error(Enliterator::Heartbeat::Overlap, /##{blocking.id}/)
      expect(Enliterator::Heartbeat.count).to eq(1)

      row, = Enliterator::Heartbeat.open!(force: true)
      expect(row.warnings.join).to include("forced past open heartbeat ##{blocking.id}")
    end
  end

  describe "#execute_async!" do
    let(:row) { Enliterator::Heartbeat.create!(started_at: Time.current, mode: "sync", budget_tokens: 1_000) }
    let(:plan) { instance_double(Enliterator::Heartbeat::Plan) }

    it "runs execute! on a named thread and returns the thread" do
      expect(row).to receive(:execute!).with(plan, skip_consider: true)
      t = row.execute_async!(plan, skip_consider: true)
      t.join
      expect(t.name).to eq("enliterator-heartbeat-#{row.id}")
    end

    it "a death OUTSIDE execute!'s own rescue still stamps the row — never a silent stop" do
      allow(row).to receive(:execute!).and_raise("finalize exploded")
      row.execute_async!(plan).join

      row.reload
      expect(row.finished_at).to be_present
      expect(row.error).to include("finalize exploded")
    end

    it "doesn't clobber a row execute! already finalized with its own error" do
      allow(row).to receive(:execute!) do
        row.update!(finished_at: Time.current, error: "the real story")
        raise "re-raised after finalize"
      end
      row.execute_async!(plan).join
      expect(row.reload.error).to eq("the real story")
    end
  end
end
