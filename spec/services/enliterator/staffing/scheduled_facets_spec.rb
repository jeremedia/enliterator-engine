# frozen_string_literal: true

require "rails_helper"

# v0.25 — `scheduled: false`: a facet that is fully staffed (tier, vocabulary,
# required terms all resolve for manual/orchestrated tending) but NEVER enters
# heartbeat lane planning. The no-unsupervised-deep-reads pin.
RSpec.describe "Staffing::Policy scheduled facets" do
  def policy!
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        facet :inventory, tier: "cheap", terms: { shelf: "Where it sits." }, scheduled: false
        context "theses" do
          facet :significance, tier: "cheap", terms: { contribution: "What it adds." }
          facet :analysis, tier: "cheap", scheduled: false, required: [ :summary ],
                terms: { summary: "Reading note.", argument: "The position advanced." }
        end
        ladder [ "cheap" ]
      end
    end
    Enliterator.staffing
  end

  it "stays fully staffed: tier, vocabulary, and required terms resolve for deliberate tending" do
    policy = policy!
    expect(policy.tier_for("analysis", path: [ "theses" ])).to eq("cheap")
    expect(policy.terms_for("analysis", path: [ "theses" ]).keys).to include("argument")
    expect(policy.required_terms("analysis", path: [ "theses" ])).to eq([ "summary" ])
  end

  it "is excluded from schedulable facets while facets_declared_in keeps the full set" do
    policy = policy!
    expect(policy.facets_declared_in("theses")).to contain_exactly("significance", "analysis")
    expect(policy.schedulable_facets_declared_in("theses")).to eq([ "significance" ])
    expect(policy.facets_declared_in(nil)).to contain_exactly("summary", "inventory")
    expect(policy.schedulable_facets_declared_in(nil)).to eq([ "summary" ])
    expect(policy.scheduled?("analysis", "theses")).to be(false)
    expect(policy.scheduled?("significance", "theses")).to be(true)
  end

  it "never enters the heartbeat plan — scheduled lanes only" do
    policy!
    ctx = Enliterator::Context.create!(key: "theses", name: "Theses")
    w   = Widget.create!(title: "T", body: "b")
    w.place_in_context!(ctx)

    plan   = Enliterator::Heartbeat.plan
    facets = plan.items.map(&:facet).uniq
    expect(facets).to include("summary", "significance")
    expect(facets).not_to include("analysis", "inventory")
  end
end
