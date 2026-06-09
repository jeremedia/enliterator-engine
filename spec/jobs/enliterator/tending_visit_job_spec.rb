# frozen_string_literal: true

require "rails_helper"

# v0.15 — the job's grown signature. Old 2-arg jobs (already serialized in a
# host's queue) keep working unchanged; the new shape threads context +
# heartbeat provenance through to tend!. heartbeat_id is a plain integer, so a
# deleted ledger row degrades to nil instead of failing deserialization.
RSpec.describe Enliterator::TendingVisitJob do
  let(:widget) { Widget.create!(title: "T", body: "b") }

  it "performs the legacy 2-arg shape exactly as before" do
    expect(widget).to receive(:tend!)
      .with(facet: "summary", context: nil, heartbeat: nil, reason: nil)
    described_class.new.perform(widget, "summary")
  end

  it "threads context, heartbeat, and reason through to tend!" do
    ctx  = Enliterator::Context.create!(key: "crs-reports", name: "CRS")
    beat = Enliterator::Heartbeat.create!(started_at: Time.current, budget_tokens: 1)

    expect(widget).to receive(:tend!)
      .with(facet: "policy_analysis", context: ctx, heartbeat: beat, reason: "frontier")
    described_class.new.perform(widget, "policy_analysis", ctx,
                                heartbeat_id: beat.id, reason: "frontier")
  end

  it "degrades a deleted heartbeat to nil rather than failing" do
    expect(widget).to receive(:tend!)
      .with(facet: "summary", context: nil, heartbeat: nil, reason: "sweep")
    described_class.new.perform(widget, "summary", nil, heartbeat_id: -1, reason: "sweep")
  end
end
