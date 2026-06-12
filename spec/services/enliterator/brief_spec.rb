# frozen_string_literal: true

require "rails_helper"

# v0.27 — the Brief: the morning question as one read. Breadth over a time
# window (cycles, work, failures with reasons, readings, governance motion),
# composed from the records the engine already keeps.
RSpec.describe Enliterator::Brief do
  include ActiveSupport::Testing::TimeHelpers

  let(:widget) { Widget.create!(title: "T", body: "## A\ntext") }

  def visit!(record, facet: "summary", status: "succeeded", tier: "cheap",
             reason: "frontier", tokens: { "total" => 100 }, error: nil, at: Time.current)
    record.enliterator_visits.create!(
      facet: facet, status: status, tier: tier, reason: reason,
      tokens: tokens, error: error, created_at: at, started_at: at
    )
  end

  it "windows: only activity after `since` appears, and a Duration reads as ago" do
    visit!(widget, at: 3.days.ago)
    visit!(widget, at: 1.hour.ago)

    brief = described_class.report(since: 12.hours)
    expect(brief[:visits][:total]).to eq(1)
    expect(brief[:window][:hours]).to be_within(0.2).of(12.0)
    expect(described_class.report(since: 4.days)[:visits][:total]).to eq(2)
  end

  it "rolls up visits by facet/tier/reason with token totals, and writes the headline" do
    visit!(widget, facet: "summary", tier: "cheap", tokens: { "total" => 100 })
    visit!(widget, facet: "authorship", tier: "quality", reason: "source_change", tokens: { "total" => 50 })
    visit!(widget, facet: "summary", status: "failed", error: "gateway down", tokens: {})

    v = described_class.report[:visits]
    expect(v[:total]).to eq(3)
    expect(v[:by_facet]["summary"]).to eq("failed" => 1, "succeeded" => 1)
    expect(v[:by_tier]).to include("cheap" => 2, "quality" => 1)
    expect(v[:by_reason]).to include("frontier" => 2, "source_change" => 1)
    expect(v[:tokens]).to eq(150)
    expect(described_class.report[:headline]).to include("3 visits (1 failed)", "150 tokens")
  end

  it "surfaces failures WITH their recorded errors, bounded and flagged" do
    12.times { |i| visit!(widget, status: "failed", error: "boom #{i}") }

    f = described_class.report[:failures]
    expect(f[:count]).to eq(12)
    expect(f[:sample].size).to eq(10)             # FAILURE_SAMPLE cap
    expect(f[:truncated]).to be(true)
    expect(f[:sample].first[:error]).to match(/\Aboom/)
    expect(f[:sample].first[:record]).to eq("Widget/#{widget.id}")
  end

  it "compacts heartbeat ledger rows: planned, executed rollup, tokens, error" do
    Enliterator::Heartbeat.create!(
      started_at: 2.hours.ago, finished_at: 2.hours.ago + 5.minutes, mode: "sync",
      planned: { "counts" => { "frontier" => 3 } },
      executed: { "summary" => { "succeeded" => 2, "failed" => 1 } },
      tokens_spent: { "total" => 900 }, warnings: [ "w1" ]
    )
    Enliterator::Heartbeat.create!(started_at: 2.days.ago, mode: "sync")   # outside window

    beats = described_class.report[:heartbeats]
    expect(beats.size).to eq(1)
    expect(beats.first).to include(mode: "sync", planned: 3, tokens: 900, warnings: [ "w1" ])
    expect(beats.first[:executed]).to eq("succeeded" => 2, "failed" => 1)
  end

  it "rolls deep-read part visits up to their records (sessions, not page turns)" do
    parts = Enliterator::Part.refresh_for!(widget, [ { heading: "A", text: "t1" }, { heading: "B", text: "t2" } ])
    visit!(parts[0], facet: "analysis", reason: "deep_read", tokens: { "total" => 10 })
    visit!(parts[1], facet: "analysis", reason: "deep_read", status: "failed", tokens: {})
    visit!(widget, facet: "summary", reason: "deep_read", tokens: { "total" => 5 })
    # An escalation chain writes junior AND senior rows for ONE synthesis —
    # counts are distinct, not row tallies (tokens stay a true sum).
    visit!(widget, facet: "summary", reason: "deep_read", tier: "quality", tokens: { "total" => 20 })

    r = described_class.report[:readings]
    expect(r).to eq(records: 1, parts_read: 1, parts_failed: 1, syntheses: 1, tokens: 35)
  end

  it "reports governance motion: suggestions filed, terms moved, audits by source" do
    visit = visit!(widget)
    claim = widget.enliterator_claims.create!(key: "topic", value: "x", status: "live", visit: visit)
    Enliterator::Suggestion.create!(tendable: widget, facet: "summary", proposed_key: "audience",
                                    rationale: "r", status: "pending")
    Enliterator::Audit.create!(claim: claim, source: "agent", auditor: "mcp-agent",
                               verdict: "unsupported", rationale: "r")

    g = described_class.report[:governance]
    expect(g[:suggestions]).to eq("pending" => 1)
    expect(g[:audits]).to eq("agent" => { "unsupported" => 1 })
  end

  it "stays calm on an empty window (the quiet night)" do
    brief = described_class.report
    expect(brief[:visits][:total]).to eq(0)
    expect(brief[:headline]).to include("0 heartbeats", "0 visits")
    expect(brief[:failures]).to eq(count: 0, sample: [], truncated: false)
    expect(brief[:readings][:records]).to eq(0)
  end
end
