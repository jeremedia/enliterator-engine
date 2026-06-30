# frozen_string_literal: true

require "rails_helper"

# ConsidererRun: the async considerer ledger.
# Mirrors Heartbeat's open!/execute_async!/reap! pattern (v0.16/v0.23 template).
RSpec.describe "Enliterator::ConsidererRun" do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
    end
  end

  # ── open! ────────────────────────────────────────────────────────────────────

  describe ".open!" do
    it "creates a running row and returns it" do
      run = Enliterator::ConsidererRun.open!
      expect(run).to be_persisted
      expect(run.status).to eq("running")
      expect(run.started_at).to be_within(2.seconds).of(Time.current)
      expect(run.finished_at).to be_nil
      expect(run.batch_size).to eq(Enliterator.configuration.considerer_batch_size)
    end

    it "sets context_id when a context is given" do
      ctx = Enliterator::Context.create!(key: "test-ctx", name: "Test")
      run = Enliterator::ConsidererRun.open!(context: ctx)
      expect(run.context_id).to eq(ctx.id)
    end

    it "context_id is nil for the root scope (no context given)" do
      run = Enliterator::ConsidererRun.open!
      expect(run.context_id).to be_nil
    end

    it "raises Overlap when an unfinished run younger than the window exists" do
      blocking = Enliterator::ConsidererRun.create!(status: "running", started_at: 1.hour.ago)
      expect { Enliterator::ConsidererRun.open! }
        .to raise_error(Enliterator::ConsidererRun::Overlap, /##{blocking.id}/)
      # No second row was created
      expect(Enliterator::ConsidererRun.count).to eq(1)
    end

    it "an unfinished run OLDER than the overlap window is not blocking" do
      Enliterator::ConsidererRun.create!(status: "running",
                                         started_at: (Enliterator::ConsidererRun::OVERLAP_WINDOW + 1.minute).ago,
                                         finished_at: nil)
      expect { Enliterator::ConsidererRun.open! }.not_to raise_error
    end

    it "reap_orphans! runs first — a stale orphan inside the window does not block" do
      orphan = Enliterator::ConsidererRun.create!(status: "running", started_at: 1.hour.ago)
      orphan.update_columns(pulse_at: (Enliterator::ConsidererRun::REAP_AFTER + 5.minutes).ago)
      expect { Enliterator::ConsidererRun.open! }.not_to raise_error
      expect(orphan.reload.status).to eq("reaped")
    end
  end

  # ── reap_orphans! / reap! / orphaned? ────────────────────────────────────────

  describe "reaping" do
    def stale_run(life_ago:)
      run = Enliterator::ConsidererRun.create!(status: "running", started_at: 1.hour.ago)
      run.update_columns(pulse_at: life_ago.ago)
      run
    end

    it "reap_orphans! stamps a stale unfinished run: status reaped, finished_at = last life" do
      run = stale_run(life_ago: Enliterator::ConsidererRun::REAP_AFTER + 5.minutes)
      Enliterator::ConsidererRun.reap_orphans!
      run.reload
      expect(run.status).to eq("reaped")
      expect(run.finished_at).to be_within(2.seconds).of(run.pulse_at)
      expect(run.error).to include("considerer process died")
    end

    it "leaves a LIVE run (recent pulse) alone" do
      live = stale_run(life_ago: 1.minute)
      Enliterator::ConsidererRun.reap_orphans!
      expect(live.reload.status).to eq("running")
      expect(live.reload.finished_at).to be_nil
    end

    it "leaves finished rows alone" do
      done = Enliterator::ConsidererRun.create!(
        status: "finished", started_at: 2.hours.ago, finished_at: 2.hours.ago + 30.seconds
      )
      Enliterator::ConsidererRun.reap_orphans!
      expect(done.reload.status).to eq("finished")
    end

    it "orphaned? is true when pulse_at is past REAP_AFTER and not finished" do
      run = stale_run(life_ago: Enliterator::ConsidererRun::REAP_AFTER + 1.minute)
      expect(run.orphaned?).to be(true)
    end

    it "orphaned? is false for a live (recent pulse) unfinished run" do
      run = stale_run(life_ago: 30.seconds)
      expect(run.orphaned?).to be(false)
    end

    it "orphaned? is false for a finished run regardless of age" do
      run = Enliterator::ConsidererRun.create!(
        status: "finished", started_at: 2.hours.ago, finished_at: 2.hours.ago + 10.seconds
      )
      expect(run.orphaned?).to be(false)
    end
  end

  # ── finished? ────────────────────────────────────────────────────────────────

  describe "#finished?" do
    it "is false while running" do
      run = Enliterator::ConsidererRun.create!(status: "running", started_at: Time.current)
      expect(run.finished?).to be(false)
    end

    it "is true once finished_at is set" do
      run = Enliterator::ConsidererRun.create!(
        status: "finished", started_at: 1.minute.ago, finished_at: Time.current
      )
      expect(run.finished?).to be(true)
    end
  end

  # ── execute! drives the considerer and stamps progress ──────────────────────

  describe "#execute!" do
    let(:w) { Widget.create!(title: "A", body: "x") }

    before do
      Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "kw",
                                      rationale: "r", status: "pending")
    end

    it "stamps progress via pulse! on each batch and finalizes with summary + finished status" do
      pulses = []
      # Stub Considerer#consider! to yield twice and return a summary hash.
      allow_any_instance_of(Enliterator::Considerer).to receive(:consider!) do |_, &blk|
        blk.call(10, 20) if blk
        blk.call(20, 20) if blk
        { considered: 20, auto_mapped: 1, auto_rejected: 2, approves_recommended: 3, held: 4 }
      end
      allow_any_instance_of(Enliterator::ConsidererRun).to receive(:pulse!) do |run, done, total|
        pulses << [ done, total ]
        run.update_columns(pulse_at: Time.current, done_count: done, planned_count: total,
                           phase: "considering")
      end

      run = Enliterator::ConsidererRun.open!
      run.execute!
      run.reload

      expect(pulses).to eq([ [ 10, 20 ], [ 20, 20 ] ])
      expect(run.status).to eq("finished")
      expect(run.finished_at).to be_within(2.seconds).of(Time.current)
      expect(run.summary["considered"]).to eq(20)
      expect(run.phase).to eq("done")
    end

    it "stamps error + finished_at and re-raises when the considerer raises" do
      allow_any_instance_of(Enliterator::Considerer).to receive(:consider!).and_raise("boom")

      run = Enliterator::ConsidererRun.open!
      expect { run.execute! }.to raise_error("boom")
      run.reload
      expect(run.status).to eq("error")
      expect(run.finished_at).to be_within(2.seconds).of(Time.current)
      expect(run.error).to include("boom")
    end
  end

  # ── execute_async! ────────────────────────────────────────────────────────────

  describe "#execute_async!" do
    it "runs execute! on a named thread and returns the thread" do
      run = Enliterator::ConsidererRun.open!
      expect(run).to receive(:execute!).and_return(nil)
      t = run.execute_async!
      t.join
      expect(t.name).to eq("enliterator-considerer-#{run.id}")
    end

    it "stamps the row when a failure escapes execute! — never a silent open row" do
      run = Enliterator::ConsidererRun.open!
      allow(run).to receive(:execute!).and_raise("finalize exploded")
      run.execute_async!.join
      run.reload
      expect(run.finished_at).to be_present
      expect(run.error).to include("finalize exploded")
    end

    it "does not clobber a row execute! already stamped with its own error" do
      run = Enliterator::ConsidererRun.open!
      allow(run).to receive(:execute!) do
        run.update!(finished_at: Time.current, status: "error", error: "the real story")
        raise "re-raised after stamp"
      end
      run.execute_async!.join
      expect(run.reload.error).to eq("the real story")
    end
  end
end
