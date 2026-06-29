# frozen_string_literal: true

require "rails_helper"

# v0.48: the deployment profile — the engine declaring its own live shape.
#
# The companion to the `checking-an-enliteration` skill: instead of an agent
# carrying out-of-band knowledge about a deployment (or reading a log that
# lies), the running system describes itself. `Deployment.profile` is a pure
# read over config + the staffing policy + the registry + the ledger, and it
# is explicit about what it CANNOT introspect (schedule, log paths) — those
# live in the host's deployment doc.
RSpec.describe Enliterator::Deployment do
  subject(:profile) { described_class.profile }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        facet :significance, tier: "quality", terms: { significance: "Why it matters." }, scheduled: false
        ladder [ "cheap", "quality" ]
      end
    end
  end

  it "returns the documented top-level sections" do
    expect(profile.keys).to include(
      :generated_at, :mode, :config, :staffing, :tendables, :contexts, :heartbeat, :external
    )
    expect(profile[:generated_at]).to be_a(Time)
  end

  describe "mode" do
    it "reports the rails env and gateway readiness (false when no api key)" do
      expect(profile[:mode][:rails_env]).to eq(Rails.env.to_s)
      expect(profile[:mode][:gateway_ready]).to be(false) # default test config has no api key
      expect([ true, false ]).to include(profile[:mode][:allow_null_llm])
      expect([ true, false ]).to include(profile[:mode][:error_detail])
    end

    it "flips gateway_ready true when both base url and api key are present" do
      Enliterator.configure do |c|
        c.gateway_base_url = "https://llm.example.com/v1"
        c.gateway_api_key  = "sk-test"
      end
      expect(profile[:mode][:gateway_ready]).to be(true)
    end
  end

  describe "config" do
    it "mirrors the heartbeat config_snapshot values" do
      snap = Enliterator::Heartbeat.config_snapshot
      expect(profile[:config][:heartbeat_budget_tokens]).to eq(snap["heartbeat_budget_tokens"])
      expect(profile[:config][:heartbeat_change_share]).to eq(snap["heartbeat_change_share"])
      expect(profile[:config][:stale_after_seconds]).to eq(snap["stale_after_seconds"])
      expect(profile[:config][:apply_approved_keys]).to eq(snap["apply_approved_keys"])
    end

    it "widens it with operational knobs the snapshot omits" do
      expect(profile[:config].keys).to include(
        :heartbeat_audit_sample, :record_lacunae, :atlas_node_cap,
        :gateway_timeout, :gateway_max_retries
      )
      expect(profile[:config][:atlas_node_cap]).to eq(Enliterator.configuration.atlas_node_cap)
    end
  end

  describe "staffing" do
    it "reports the ladder, the referenced tiers, and the effective verify floor" do
      expect(profile[:staffing][:ladder]).to eq(%w[cheap quality])
      expect(profile[:staffing][:tiers]).to include("cheap", "quality")
      expect(profile[:staffing][:verify_floor]).to eq("quality") # ladder.last
    end

    it "lists each facet with its tier and whether the pacemaker schedules it" do
      summary = profile[:staffing][:facets].find { |f| f[:facet] == "summary" }
      signif  = profile[:staffing][:facets].find { |f| f[:facet] == "significance" }
      expect(summary).to include(tier: "cheap", scheduled: true, origin: "root")
      expect(signif).to include(tier: "quality", scheduled: false) # declared scheduled: false
    end

    # The deployment's real facet set is often mostly context-declared (HSDL
    # declares ~8 facets in context blocks, 2 at root) — showing only root would
    # under-represent what the engine actually tends.
    it "includes facets declared in context blocks, tagged by their origin context" do
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :summary, tier: "cheap", terms: { summary: "An abstract." }
          context "reports" do
            facet :directive, tier: "quality", terms: { directive: "The directive." }
          end
          ladder %w[cheap quality]
        end
      end
      directive = profile[:staffing][:facets].find { |f| f[:facet] == "directive" }
      expect(directive).to include(tier: "quality", origin: "reports", scheduled: true)
    end
  end

  describe "tendables" do
    it "lists host tendable types (visit-log first, registry fallback)" do
      w = Widget.create!(title: "A", body: "x")
      Enliterator::Visit.create!(tendable: w, facet: "summary", status: "succeeded")
      expect(profile[:tendables]).to include("Widget")
      expect(profile[:tendables]).not_to include(a_string_starting_with("Enliterator::"))
    end
  end

  describe "contexts" do
    it "reports the count and the root keys" do
      Enliterator::Context.create!(key: "alpha", name: "Alpha")
      expect(profile[:contexts][:count]).to be >= 1
      expect(profile[:contexts][:roots]).to include("alpha")
    end
  end

  describe "heartbeat" do
    it "reports the last beat and infers cadence from started_at deltas" do
      base = Time.utc(2026, 6, 1, 1, 30)
      a = Enliterator::Heartbeat.create!(started_at: base,            finished_at: base + 5.minutes,  mode: "sync")
      b = Enliterator::Heartbeat.create!(started_at: base + 24.hours, finished_at: base + 24.hours + 5.minutes, mode: "sync")
      expect(profile[:heartbeat][:last][:id]).to eq(b.id)
      expect(profile[:heartbeat][:inferred_cadence_hours]).to be_within(0.1).of(24.0)
      expect(profile[:heartbeat][:schedule]).to match(/external/i)
    end

    it "degrades gracefully with fewer than two beats" do
      expect(profile[:heartbeat][:inferred_cadence_hours]).to be_nil
      expect(profile[:heartbeat][:last]).to be_nil
      expect(profile[:heartbeat][:schedule]).to match(/external/i)
    end
  end

  describe "external" do
    it "names what it cannot introspect and points to the host doc" do
      expect(profile[:external][:host_doc]).to match(%r{doc/enliterator/deployment\.md})
      blob = profile[:external][:not_introspectable].join(" ").downcase
      expect(blob).to include("schedule")
      expect(blob).to include("log")
    end
  end
end
