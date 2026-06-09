# frozen_string_literal: true

require "rails_helper"

# v0.5 smoke alarm. Pure-read rollup over the Visit history. The headline job:
# surface a `null` adapter (a misconfigured run that wrote phantom "succeeded"
# visits) and an empty-final facet at a glance.
RSpec.describe Enliterator::Report do
  let(:widget) { Widget.create!(title: "Acme", body: "report fodder") }

  def visit!(facet:, model:, tier:, status: "succeeded", applied: true,
             esc: 0, confidence: 0.9, recon: { added: %w[summary], updated: [], deleted: [], noop: [] },
             tokens: { "input" => 10, "output" => 5, "total" => 15 })
    widget.enliterator_visits.create!(
      facet: facet, model: model, tier: tier, status: status, applied: applied,
      escalation_step: esc, confidence: confidence, reconciliation: recon, tokens: tokens
    )
  end

  describe ".summary" do
    before do
      # A healthy gateway facet + one escalation.
      visit!(facet: "summary", model: "cheap",   tier: "cheap",   confidence: 0.95)
      visit!(facet: "summary", model: "quality", tier: "quality", esc: 1, confidence: 0.92)
      # A NULL adapter run — the smoke alarm — that wrote nothing (empty final).
      visit!(facet: "authorship", model: "null", tier: "cheap", confidence: 0.0,
             recon: { added: [], updated: [], deleted: [], noop: [] })
      # A required-unmet flagged visit.
      visit!(facet: "authorship", model: "quality", tier: "quality", confidence: 0.95,
             recon: { added: %w[advisor], updated: [], deleted: [], noop: [], required_unmet: true })
    end

    it "surfaces the null adapter in the model mix" do
      r = described_class.summary
      expect(r["authorship"][:adapter_mix]).to include("null" => 1, "quality" => 1)
      expect(r["summary"][:adapter_mix]).to eq("cheap" => 1, "quality" => 1)
    end

    it "counts status, totals, and escalation rate" do
      r = described_class.summary
      expect(r["summary"][:total]).to eq(2)
      expect(r["summary"][:status]).to eq("succeeded" => 2)
      expect(r["summary"][:escalation_rate]).to eq(0.5)   # 1 of 2 escalated
    end

    it "computes the empty-final rate (a succeeded visit that wrote nothing)" do
      r = described_class.summary
      # authorship: 2 applied+succeeded, 1 with empty reconciliation → 0.5
      expect(r["authorship"][:empty_final_rate]).to eq(0.5)
    end

    it "counts required_unmet visits" do
      expect(described_class.summary["authorship"][:required_unmet]).to eq(1)
    end

    it "buckets confidence (including nil)" do
      visit!(facet: "summary", model: "cheap", tier: "cheap", confidence: nil)
      r = described_class.summary
      expect(r["summary"][:confidence]).to include("0.8-1.0" => 2, "nil" => 1)
    end

    it "merges the Spend token ledger" do
      tokens = described_class.summary["summary"].dig(:spend, :tokens)
      expect(tokens).to eq("input" => 20, "output" => 10, "total" => 30)
    end

    it "filters to a single facet" do
      expect(described_class.summary(facet: "authorship").keys).to eq(%w[authorship])
    end
  end
end
