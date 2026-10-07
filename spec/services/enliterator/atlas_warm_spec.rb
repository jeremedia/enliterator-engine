# frozen_string_literal: true

require "rails_helper"

# v0.86 — the edge index (v0.85) is cold after any claim change; a heartbeat
# cycle or an import rebuilds the configured ones so the next reader doesn't
# pay the cold build. Unconfigured ⇒ no warm step at all.
RSpec.describe "v0.86 atlas warming" do
  around do |ex|
    prior = Enliterator.configuration.atlas_warm_contexts
    ex.run
    Enliterator.configuration.atlas_warm_contexts = prior
  end

  let!(:shelf) { Enliterator::Context.create!(key: "shelf", name: "Shelf") }
  let!(:other) { Enliterator::Context.create!(key: "other", name: "Other") }

  it "unconfigured: warms nothing" do
    expect(Enliterator::Atlas).not_to receive(:edge_index)
    expect(Enliterator::Atlas.warm!).to eq({})
  end

  it "warms the named contexts and root; an unknown key is skipped, not raised" do
    allow(Enliterator::Atlas).to receive(:edge_index).and_call_original
    out = Enliterator::Atlas.warm!(%w[root shelf nope])
    expect(out.keys).to eq(%w[root shelf])
    expect(Enliterator::Atlas).to have_received(:edge_index).with(context: nil)
    expect(Enliterator::Atlas).to have_received(:edge_index).with(context: shelf)
  end

  it ":all warms root and every context" do
    expect(Enliterator::Atlas.warm!(:all).keys).to eq(%w[root shelf other])
  end

  it "a failed warm is reported, never raised" do
    allow(Enliterator::Atlas).to receive(:edge_index).and_raise(ActiveRecord::StatementInvalid, "boom")
    expect(Enliterator::Atlas.warm!(%w[shelf])).to eq("shelf" => "failed: ActiveRecord::StatementInvalid")
  end

  describe "the heartbeat" do
    it "unconfigured: no warm phase" do
      expect(Enliterator::Atlas).not_to receive(:warm!)
      Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
    end

    it "configured: warms after the audit phase" do
      Enliterator.configuration.atlas_warm_contexts = %w[shelf]
      allow(Enliterator::Atlas).to receive(:edge_index).and_call_original
      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      expect(Enliterator::Atlas).to have_received(:edge_index).with(context: shelf)
      expect(row.error).to be_nil
    end

    it "configured: a failed warm becomes a cycle warning, not an error" do
      Enliterator.configuration.atlas_warm_contexts = %w[shelf]
      allow(Enliterator::Atlas).to receive(:edge_index).and_raise(ActiveRecord::StatementInvalid, "boom")
      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      expect(row.error).to be_nil
      expect(Array(row.warnings).join).to include("atlas warm shelf: failed")
    end
  end
end
