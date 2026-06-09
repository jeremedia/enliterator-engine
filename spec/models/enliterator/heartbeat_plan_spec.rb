# frozen_string_literal: true

require "rails_helper"

# v0.15 — the planner. Event-driven, not wall-clock: budget envelopes
# (change → frontier → sweep), three change triggers anchored to lane
# MAX(started_at), set-based candidate queries, and a warning for every
# omission. Pure read.
RSpec.describe "Enliterator::Heartbeat.plan (v0.15)" do
  RSpec::Matchers.define_negated_matcher :not_change, :change

  let(:root)    { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
  let(:crs)     { Enliterator::Context.create!(key: "crs-reports", name: "CRS", parent: root) }
  let(:eo)      { Enliterator::Context.create!(key: "executive-orders", name: "EOs", parent: root) }

  def configure_policy!
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        context "crs-reports" do
          facet :policy_analysis, tier: "cheap", terms: { issue_for_congress: "The issue." }
        end
        context "executive-orders" do
          facet :directive, tier: "cheap", terms: { eo_number: "The number." }
        end
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
  end

  # Backdated so the default source_change test (host updated_at vs lane
  # started_at) doesn't claim every record before the trigger under test can —
  # records in these scenarios are "old stock" unless a test touches them.
  def widget!(title = "w", context: nil)
    w = Widget.create!(title: title, body: "b")
    w.update_columns(created_at: 90.days.ago, updated_at: 90.days.ago)
    w.place_in_context!(context) if context
    w
  end

  # A succeeded+applied lane visit with controlled clocks and real token costs
  # (est_for reads the trailing window, so every visit prices the next plan).
  def visit!(record, facet:, context: nil, at: 2.days.ago, status: "succeeded",
             applied: true, tokens: { "input" => 50, "output" => 50, "total" => 100 })
    record.enliterator_visits.create!(
      facet: facet, context: context, status: status, applied: applied, tier: "cheap",
      tokens: tokens, created_at: at, updated_at: at, started_at: at, finished_at: at + 5.seconds
    )
  end

  def items_for(plan, reason: nil, facet: nil)
    plan.items.select { |i| (reason.nil? || i.reason == reason) && (facet.nil? || i.facet == facet) }
  end

  before { configure_policy! }

  describe "frontier" do
    it "schedules untended context members and skips the already-tended (anti-join)" do
      a, b, c = widget!("a", context: crs), widget!("b", context: crs), widget!("c", context: crs)
      visit!(a, facet: "policy_analysis", context: crs)

      plan = Enliterator::Heartbeat.plan
      ids  = items_for(plan, reason: "frontier", facet: "policy_analysis").map(&:tendable_id)
      expect(ids).to contain_exactly(b.id.to_s, c.id.to_s)
      expect(plan.frontier_remaining["crs-reports/policy_analysis"]).to eq(2)
    end

    it "root lanes use explicit NULL scope — a context visit never satisfies root" do
      w = widget!("w", context: crs)
      visit!(w, facet: "summary", context: crs)   # tended on summary IN crs, never at root

      plan = Enliterator::Heartbeat.plan
      expect(items_for(plan, reason: "frontier", facet: "summary").map(&:tendable_id))
        .to include(w.id.to_s)

      visit!(w, facet: "summary")                  # now tended at root (NULL)
      plan = Enliterator::Heartbeat.plan
      expect(items_for(plan, reason: "frontier", facet: "summary").map(&:tendable_id))
        .not_to include(w.id.to_s)
    end

    it "excludes records in failure backoff and says nothing else about them" do
      bad, good = widget!("bad", context: crs), widget!("good", context: crs)
      visit!(bad, facet: "policy_analysis", context: crs, at: 1.hour.ago, status: "failed", applied: false)
      visit!(widget!("hist"), facet: "policy_analysis") # token history for est

      ids = items_for(Enliterator::Heartbeat.plan, reason: "frontier", facet: "policy_analysis")
              .map(&:tendable_id)
      expect(ids).to include(good.id.to_s)
      expect(ids).not_to include(bad.id.to_s)

      # The backoff expires: an old failure doesn't block.
      bad.enliterator_visits.update_all(created_at: 3.days.ago)
      ids = items_for(Enliterator::Heartbeat.plan, reason: "frontier", facet: "policy_analysis")
              .map(&:tendable_id)
      expect(ids).to include(bad.id.to_s)
    end

    it "spillover: with no change candidates the FULL budget reaches the frontier" do
      hist = widget!("hist", context: crs)
      visit!(hist, facet: "policy_analysis", context: crs, at: 30.days.ago,
             tokens: { "total" => 100 })                       # est = 100/item
      8.times { |i| widget!("f#{i}", context: crs) }

      # Budget for exactly 4 items; change envelope (20%) has no candidates —
      # cooldown shields hist from the neighborhood trigger.
      plan = Enliterator::Heartbeat.plan(budget: 400)
      expect(plan.items.size).to be >= 4
      expect(plan.items.map(&:reason).uniq).to eq([ "frontier" ])
    end

    it "horizon math: remaining shelf ÷ budget, in cycles" do
      visit!(widget!("hist", context: crs), facet: "policy_analysis", context: crs,
             at: 30.days.ago, tokens: { "total" => 100 })
      9.times { |i| widget!("f#{i}", context: crs) }

      plan = Enliterator::Heartbeat.plan(budget: 300)
      expect(plan.frontier_total).to be >= 9
      expect(plan.horizon_cycles).to be >= 3
      expect(plan.horizon_line).to match(/frontier: \d+ record\(s\) remaining/)
    end
  end

  describe "source_change trigger" do
    it "schedules a record whose host row moved after its last lane START" do
      changed, stable = widget!("changed", context: crs), widget!("stable", context: crs)
      visit!(changed, facet: "policy_analysis", context: crs, at: 2.days.ago)
      visit!(stable,  facet: "policy_analysis", context: crs, at: 2.days.ago)
      changed.update_columns(updated_at: 1.hour.ago)
      stable.update_columns(updated_at: 3.days.ago)

      ids = items_for(Enliterator::Heartbeat.plan, reason: "source_change").map(&:tendable_id)
      expect(ids).to include(changed.id.to_s)
      expect(ids).not_to include(stable.id.to_s)
    end

    it "honors the host override callable instead of updated_at" do
      Enliterator.configuration.heartbeat_source_changed = ->(record, _last) { record.title == "CHANGED" }
      a, b = widget!("CHANGED", context: crs), widget!("same", context: crs)
      visit!(a, facet: "policy_analysis", context: crs, at: 2.days.ago)
      visit!(b, facet: "policy_analysis", context: crs, at: 2.days.ago)
      b.update_columns(updated_at: Time.current)   # would trip the default test

      ids = items_for(Enliterator::Heartbeat.plan, reason: "source_change").map(&:tendable_id)
      expect(ids).to contain_exactly(a.id.to_s)
    end
  end

  describe "vocabulary trigger" do
    def approve!(facet:, context: nil, at: Time.current, key: "new_term")
      s = Enliterator::Suggestion.create!(tendable: widget!("prop"), facet: facet,
                                          context: context, proposed_key: key, status: "approved")
      s.update_columns(updated_at: at)
      s
    end

    it "schedules records last STARTED before the approval, oldest first; a re-tend clears them" do
      old, fresh = widget!("old", context: crs), widget!("fresh", context: crs)
      visit!(old,   facet: "policy_analysis", context: crs, at: 10.days.ago)
      visit!(fresh, facet: "policy_analysis", context: crs, at: 10.days.ago)
      approve!(facet: "policy_analysis", context: crs, at: 5.days.ago)
      visit!(fresh, facet: "policy_analysis", context: crs, at: 1.day.ago)   # caught up

      ids = items_for(Enliterator::Heartbeat.plan, reason: "vocabulary").map(&:tendable_id)
      expect(ids).to include(old.id.to_s)
      expect(ids).not_to include(fresh.id.to_s)
    end

    it "anchors on started_at — a visit that merely FINISHED after the approval is still due" do
      w = widget!("racer", context: crs)
      v = visit!(w, facet: "policy_analysis", context: crs, at: 5.days.ago)
      approve!(facet: "policy_analysis", context: crs, at: 5.days.ago + 2.seconds)
      v.update_columns(finished_at: 5.days.ago + 10.minutes)   # finished after the approval

      ids = items_for(Enliterator::Heartbeat.plan, reason: "vocabulary").map(&:tendable_id)
      expect(ids).to include(w.id.to_s)
    end

    it "reads approvals UP the path (a root approval reaches the context lane) and never from siblings" do
      w = widget!("w", context: crs)
      visit!(w, facet: "policy_analysis", context: crs, at: 10.days.ago)
      approve!(facet: "policy_analysis", context: eo, at: 5.days.ago, key: "sibling_term")
      expect(items_for(Enliterator::Heartbeat.plan, reason: "vocabulary")).to be_empty

      approve!(facet: "policy_analysis", context: nil, at: 5.days.ago, key: "root_term")
      ids = items_for(Enliterator::Heartbeat.plan, reason: "vocabulary").map(&:tendable_id)
      expect(ids).to include(w.id.to_s)
    end

    it "is gated on apply_approved_keys and says why" do
      Enliterator.configuration.apply_approved_keys = false
      w = widget!("w", context: crs)
      visit!(w, facet: "policy_analysis", context: crs, at: 10.days.ago)
      approve!(facet: "policy_analysis", context: crs)

      plan = Enliterator::Heartbeat.plan
      expect(items_for(plan, reason: "vocabulary")).to be_empty
      expect(plan.warnings.join).to include("apply_approved_keys is false")
    end

    it "a budget-cut wave logs its drain arithmetic and resumes next cycle (zero new state)" do
      # All visits inside the 9-day neighborhood cooldown, so the wave is the
      # ONLY change signal and the envelope math is observable in isolation.
      hist = widget!("hist", context: crs)
      visit!(hist, facet: "policy_analysis", context: crs, at: 8.days.ago, tokens: { "total" => 100 })
      ws = 5.times.map { |i| widget!("w#{i}", context: crs) }
      ws.each_with_index { |w, i| visit!(w, facet: "policy_analysis", context: crs, at: (7 - i).days.ago) }
      approve!(facet: "policy_analysis", context: crs, at: 1.day.ago)

      # change cap = 200 tokens = 2 items at est 100.
      plan = Enliterator::Heartbeat.plan(budget: 1_000)
      vocab = items_for(plan, reason: "vocabulary")
      expect(vocab.size).to eq(2)
      # Oldest-tended first — the cursor.
      expect(vocab.map(&:tendable_id)).to eq([ hist.id.to_s, ws[0].id.to_s ])
      expect(plan.warnings.join).to match(/vocabulary: .* wave has 4 record\(s\) remaining/)
    end
  end

  describe "neighborhood trigger" do
    # Cooldown default is max(stale_after/10, 1.day) = 9 days; mates must trip
    # the threshold AFTER the record's last visit, with the record outside cooldown.
    def seat_and_tend_all!(records, at:)
      records.each { |r| visit!(r, facet: "policy_analysis", context: crs, at: at) }
    end

    it "fires when ≥ threshold mates were tended after the record's last lane visit" do
      a = widget!("a", context: crs)
      mates = 3.times.map { |i| widget!("m#{i}", context: crs) }
      visit!(a, facet: "policy_analysis", context: crs, at: 30.days.ago)
      seat_and_tend_all!(mates, at: 2.days.ago)

      ids = items_for(Enliterator::Heartbeat.plan, reason: "neighborhood").map(&:tendable_id)
      expect(ids).to include(a.id.to_s)
      expect(ids).not_to include(*mates.map { |m| m.id.to_s })   # mates are fresh
    end

    it "stays quiet under the threshold" do
      a = widget!("a", context: crs)
      mates = 2.times.map { |i| widget!("m#{i}", context: crs) }
      visit!(a, facet: "policy_analysis", context: crs, at: 30.days.ago)
      seat_and_tend_all!(mates, at: 2.days.ago)

      expect(items_for(Enliterator::Heartbeat.plan, reason: "neighborhood")).to be_empty
    end

    it "is suppressed while the lane's frontier is non-empty — and says so" do
      a = widget!("a", context: crs)
      mates = 3.times.map { |i| widget!("m#{i}", context: crs) }
      visit!(a, facet: "policy_analysis", context: crs, at: 30.days.ago)
      seat_and_tend_all!(mates, at: 2.days.ago)
      widget!("unread", context: crs)   # the shelf is not finished

      plan = Enliterator::Heartbeat.plan
      expect(items_for(plan, reason: "neighborhood")).to be_empty
      expect(plan.warnings.join).to include("neighborhood: crs-reports/policy_analysis suppressed")
    end

    it "respects the per-record cooldown" do
      a = widget!("a", context: crs)
      mates = 3.times.map { |i| widget!("m#{i}", context: crs) }
      visit!(a, facet: "policy_analysis", context: crs, at: 2.days.ago)   # inside cooldown
      seat_and_tend_all!(mates, at: 1.day.ago)

      expect(items_for(Enliterator::Heartbeat.plan, reason: "neighborhood")).to be_empty
    end

    it "pre-gates quiet lanes once a finished beat exists" do
      a = widget!("a", context: crs)
      mates = 3.times.map { |i| widget!("m#{i}", context: crs) }
      visit!(a, facet: "policy_analysis", context: crs, at: 30.days.ago)
      seat_and_tend_all!(mates, at: 10.days.ago)
      Enliterator::Heartbeat.create!(started_at: 2.days.ago, finished_at: 2.days.ago + 1.hour)

      expect(items_for(Enliterator::Heartbeat.plan, reason: "neighborhood")).to be_empty
    end
  end

  describe "sweep (the demoted safety net)" do
    it "re-tends only records staler than stale_after, with leftover budget, oldest first" do
      Enliterator.configuration.stale_after = 30.days
      stale, fresh = widget!("stale", context: crs), widget!("fresh", context: crs)
      visit!(stale, facet: "policy_analysis", context: crs, at: 60.days.ago)
      visit!(fresh, facet: "policy_analysis", context: crs, at: 2.days.ago)

      plan = Enliterator::Heartbeat.plan
      ids = items_for(plan, reason: "sweep").map(&:tendable_id)
      expect(ids).to include(stale.id.to_s)
      expect(ids).not_to include(fresh.id.to_s)
    end

    it "never duplicates a record another reason already claimed" do
      Enliterator.configuration.stale_after = 30.days
      w = widget!("both", context: crs)
      visit!(w, facet: "policy_analysis", context: crs, at: 60.days.ago)
      w.update_columns(updated_at: 1.hour.ago)   # also a source_change candidate

      plan = Enliterator::Heartbeat.plan
      mine = plan.items.select { |i| i.tendable_id == w.id.to_s && i.facet == "policy_analysis" }
      expect(mine.size).to eq(1)
      expect(mine.first.reason).to eq("source_change")   # correctness outranks the sweep
    end
  end

  describe "cost estimation" do
    it "prices escalation chains in: all succeeded tokens ÷ applied visits" do
      w = widget!("w", context: crs)
      # One item that escalated: junior (applied false) + senior (applied true).
      visit!(w, facet: "policy_analysis", context: crs, at: 3.days.ago,
             applied: false, tokens: { "total" => 100 })
      visit!(w, facet: "policy_analysis", context: crs, at: 3.days.ago + 1.minute,
             tokens: { "total" => 300 })
      widget!("f", context: crs)

      plan = Enliterator::Heartbeat.plan
      frontier = items_for(plan, reason: "frontier", facet: "policy_analysis")
      expect(frontier.first.est_tokens).to eq(400)   # (100+300)/1 applied
    end

    it "falls back (global mean, then the engine default) and logs which" do
      widget!("f", context: crs)
      plan = Enliterator::Heartbeat.plan
      expect(items_for(plan, reason: "frontier", facet: "policy_analysis").first.est_tokens).to eq(4_000)
      expect(plan.warnings.join).to include("no token history")
    end
  end

  it "is a PURE READ — planning writes nothing" do
    w = widget!("w", context: crs)
    visit!(w, facet: "policy_analysis", context: crs, at: 40.days.ago)
    widget!("f", context: crs)

    expect {
      Enliterator::Heartbeat.plan
    }.to not_change(Enliterator::Visit, :count)
      .and not_change(Enliterator::Heartbeat, :count)
      .and not_change(Enliterator::Claim, :count)
  end
end
