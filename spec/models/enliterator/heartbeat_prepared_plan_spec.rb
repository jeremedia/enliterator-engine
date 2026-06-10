require "rails_helper"

# v0.20: the prepared plan — a ledger row's `planned` jsonb read back through
# the same interface the previews render from a live Plan. The invariant that
# matters: a PreparedPlan built from a row written by Plan#to_ledger renders
# the same preview the live plan would have.
RSpec.describe Enliterator::Heartbeat::PreparedPlan do
  def live_plan(items: [], budget: 1000, frontier_remaining: {}, horizon_tokens: 0, warnings: [])
    Enliterator::Heartbeat::Plan.new(
      budget: budget, change_cap: 200, items: items, warnings: warnings,
      frontier_remaining: frontier_remaining, horizon_tokens: horizon_tokens
    )
  end

  def ledger_row_for(plan)
    Enliterator::Heartbeat.create!(
      mode: "sync", budget_tokens: plan.budget, planned: plan.to_ledger,
      started_at: Time.current
    )
  end

  it "renders the same preview a live plan would (the to_ledger round-trip)" do
    items = [
      Enliterator::Heartbeat::Plan::Item.new(
        tendable_type: "Widget", tendable_id: "1", facet: "summary",
        context: nil, reason: "frontier", est_tokens: 100
      ),
      Enliterator::Heartbeat::Plan::Item.new(
        tendable_type: "Widget", tendable_id: "2", facet: "summary",
        context: nil, reason: "source_change", est_tokens: 100
      )
    ]
    plan = live_plan(items: items, frontier_remaining: { "root/summary" => 50 },
                     horizon_tokens: 5_000, warnings: [ "a note" ])
    prepared = described_class.new(ledger_row_for(plan))

    expect(prepared.counts).to       eq(plan.counts)
    expect(prepared.lane_counts).to  eq(plan.lane_counts)
    expect(prepared.est_total).to    eq(plan.est_total)
    expect(prepared.budget).to       eq(plan.budget)
    expect(prepared.warnings).to     eq(plan.warnings)
    expect(prepared.horizon_line).to eq(plan.horizon_line)
    expect(prepared.work?).to        eq(plan.work?)
  end

  it "renders 'frontier: clear' identically when the shelf is empty" do
    plan = live_plan
    prepared = described_class.new(ledger_row_for(plan))
    expect(plan.horizon_line).to     eq("frontier: clear")
    expect(prepared.horizon_line).to eq("frontier: clear")
    expect(prepared.work?).to be(false)
  end

  it "carries the revision date; a live plan has none" do
    row = ledger_row_for(live_plan)
    prepared = described_class.new(row)
    expect(prepared.as_of).to eq([ row.id, row.started_at ])
    expect(live_plan.as_of).to be_nil
  end

  it "tolerates a row with empty planned jsonb (crash evidence, not a crash)" do
    row = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 500,
                                         planned: {}, started_at: Time.current)
    prepared = described_class.new(row)
    expect(prepared.work?).to be(false)
    expect(prepared.horizon_line).to eq("frontier: clear")
    expect(prepared.warnings).to eq([])
  end
end
