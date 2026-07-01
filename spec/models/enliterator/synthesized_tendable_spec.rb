# frozen_string_literal: true

require "rails_helper"

# Item 4 (composite work): a host tendable listed in `config.synthesized_tendables`
# is tended only by deliberate invocation (a rake) — masked out of the pacemaker's
# scheduling AND the type-census rollups, while staying a real, drillable tendable
# (`tendable_type?` stays true; its claims still reach the claim store). The mask is
# a pure NAME-subtraction (`Enliterator.mask_synthesized`) applied to each consumer's
# own base, so it is load-independent (correct in a cold process) and byte-identical
# when the list is empty (hard rule 1). The three integration consumers below cover
# the three distinct base shapes — planner (union), Deployment (host_types||registry),
# Synopsis (registry-only) — every other consumer routes through the same helper.
RSpec.describe "Synthesized tendables (composite-work wholes)" do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
  end

  # A tended Widget: registered (class is loaded) AND present in the visit log.
  def tended_widget!
    w = Widget.create!(title: "W", body: "b")
    w.enliterator_visits.create!(
      facet: "summary", status: "succeeded", applied: true, tier: "cheap",
      started_at: 2.days.ago, finished_at: 2.days.ago + 5.seconds
    )
    w
  end

  def planner_root_models
    Enliterator::Heartbeat::Planner.new.send(:root_lanes).map(&:model)
  end

  describe "Enliterator.mask_synthesized (the primitive)" do
    it "returns names unchanged when the list is empty (byte-identical)" do
      Enliterator.configuration.synthesized_tendables = []
      expect(Enliterator.mask_synthesized(%w[Widget Manuscript])).to eq(%w[Widget Manuscript])
    end

    it "subtracts listed names, order-preserving, and is nil-safe" do
      Enliterator.configuration.synthesized_tendables = %w[Manuscript]
      expect(Enliterator.mask_synthesized(%w[Widget Manuscript Chapter])).to eq(%w[Widget Chapter])
      Enliterator.configuration.synthesized_tendables = nil
      expect(Enliterator.mask_synthesized(%w[Widget])).to eq(%w[Widget]) # Array() wrap
    end
  end

  describe "empty list ⇒ byte-identical (rule 1)" do
    before { Enliterator.configuration.synthesized_tendables = [] }

    it "keeps a tended host type in planner root lanes and every census consumer" do
      tended_widget!
      expect(planner_root_models).to include(Widget)
      expect(Enliterator::Deployment.profile[:tendables]).to include("Widget")
      expect(Enliterator::Synopsis.build[:models]).to include("Widget")
    end
  end

  describe "a listed type is masked from scheduling + census" do
    before { Enliterator.configuration.synthesized_tendables = %w[Widget] }

    it "drops it from planner root lanes (no chapter-facet × whole lane)" do
      tended_widget!
      expect(planner_root_models).not_to include(Widget)
    end

    it "drops it from the union and host||registry and registry-only census bases" do
      tended_widget!
      expect(Enliterator::Deployment.profile[:tendables]).not_to include("Widget")
      expect(Enliterator::Synopsis.build[:models]).not_to include("Widget")
    end

    it "yet stays a real tendable TYPE — tendable_type? true, claims still surface" do
      w = tended_widget!
      w.enliterator_claims.create!(
        key: "summary", value: "the whole argues X", confidence: 1.0,
        status: "verified", visit: w.enliterator_visits.last
      )
      expect(Enliterator.tendable_type?(Widget)).to be(true) # drill-down (status#show) works
      expect(Enliterator::Claim.live.understanding.where(tendable: w)).to be_present
    end
  end

  describe "cold-process: a name-only visit type is masked without loading its class" do
    it "excludes a synthesized type present ONLY via host_tendable_types (never constantized)" do
      # A visit whose tendable_type never resolves to a loaded class — the exact
      # state a fresh `rake … PLAN=1` process sees. Build a real visit, then
      # rewrite its type via update_columns (no AR constantize of the polymorphic
      # type). Name-subtraction excludes it regardless of load state; a class-body
      # mask would miss it (the v0.25 race).
      w = Widget.create!(title: "g", body: "b")
      v = w.enliterator_visits.create!(
        facet: "thesis", status: "succeeded", tier: "cheap",
        started_at: 1.day.ago, finished_at: 1.day.ago + 1.second
      )
      v.update_columns(tendable_type: "GhostBook")
      expect(Enliterator::Deployment.profile[:tendables]).to include("GhostBook") # unmasked baseline
      Enliterator.configuration.synthesized_tendables = %w[GhostBook]
      expect(Enliterator::Deployment.profile[:tendables]).not_to include("GhostBook")
    end
  end
end
