# frozen_string_literal: true

require "rails_helper"

# v0.41.1 — graceful bedrock auth lapse. The campaign/grant tier is bedrock and
# ONLY bedrock; an expired AWS SSO session is a re-auth PAUSE, not a failure. A
# lapse must DEFER the bedrock work (leave the record on the frontier), keep the
# rest of the cycle going, and finish CLEAN — no error stamp, no re-raise (exit
# 0) — so the considerer still runs and the next beat, after re-auth, picks the
# deferred work back up. Strictly bedrock: a real (non-bedrock) failure stays
# fatal exactly as before.
RSpec.describe "Enliterator::Heartbeat bedrock auth lapse (v0.41.1)" do
  let(:root) { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
  let(:crs)  { Enliterator::Context.create!(key: "crs-reports", name: "CRS", parent: root) }

  # The LiteLLM-wrapped expired-token 500 HSDL actually sees.
  LAPSE_MSG =
    'litellm: BedrockException {"message":"The security token included in the request is expired"} ' \
    "model_group=bedrock-sonnet"
  # id=56's mode: a bedrock call timed out (token valid, but the gateway/bedrock
  # was slow). No tier marker in the message — a timeout is transient on any tier.
  TIMEOUT_MSG = "OpenAI::Errors::APITimeoutError: Request timed out."

  def configure!(llm)
    Enliterator.configure do |c|
      c.tending_facets = []
      c.staffing = Enliterator::Staffing::Policy.new do
        context "crs-reports" do
          facet :policy_analysis, tier: "cheap", terms: { issue_for_congress: "The issue." }
        end
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(llm)
  end

  # Tends succeed (cost 100) except: "bedrock-down" records raise the LiteLLM
  # expired-token error (a bedrock lapse); "boom" records raise a generic error
  # (a real failure). `decide` raises the lapse when decide_lapses is set.
  class LapseStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    attr_accessor :decide_lapses, :decide_times_out

    def initialize
      @decide_lapses = false
      @decide_times_out = false
    end

    def model_id = "model-cheap"

    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      raise LAPSE_MSG   if text.include?("bedrock-down")
      raise TIMEOUT_MSG if text.include?("timeout")
      raise "boom"      if text.include?("boom")
      Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {},
                 tokens: { "input" => 50, "output" => 50, "total" => 100 })
    end

    def decide(messages:, schema:, tool_name:, tags: [])
      raise LAPSE_MSG   if @decide_lapses
      raise TIMEOUT_MSG if @decide_times_out
      { "recommendations" => [] }
    end
  end

  def widget!(title, context: crs)
    w = Widget.create!(title: title, body: "b")
    w.update_columns(created_at: 90.days.ago, updated_at: 90.days.ago)
    w.place_in_context!(context)
    w
  end

  def seed_history!
    w = widget!("hist")
    w.enliterator_visits.create!(
      facet: "policy_analysis", context: crs, status: "succeeded", applied: true, tier: "cheap",
      tokens: { "input" => 50, "output" => 50, "total" => 100 },
      created_at: 40.days.ago, updated_at: 40.days.ago,
      started_at: 40.days.ago, finished_at: 40.days.ago + 5.seconds
    )
    w
  end

  it "DEFERS a lapsing item, keeps tending the rest, and finishes clean" do
    configure!(LapseStubLLM.new)
    seed_history!
    widget!("ok-1"); widget!("bedrock-down"); widget!("ok-2")

    row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)

    expect(row.executed.dig("frontier", "succeeded")).to eq(2)
    expect(row.executed.dig("frontier", "deferred")).to eq(1)
    expect(row.executed.dig("frontier", "failed").to_i).to eq(0)
    expect(row.error).to be_nil
    expect(row).to be_finished
    expect(row.warnings.join).to match(/bedrock unavailable/i)
  end

  it "does NOT trip the misconfiguration abort when the first items ALL lapse" do
    configure!(LapseStubLLM.new)
    seed_history!
    6.times { |i| widget!("bedrock-down-#{i}") }

    expect {
      @row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
    }.not_to raise_error

    expect(@row.error).to be_nil
    expect(@row).to be_finished
    expect(@row.executed.dig("frontier", "deferred")).to eq(6)
    expect(@row.executed.dig("frontier", "failed").to_i).to eq(0)
  end

  it "holds a lapsing considerer scope but still finishes the cycle clean" do
    llm = LapseStubLLM.new
    llm.decide_lapses = true
    configure!(llm)
    w = seed_history!
    Enliterator::Suggestion.create!(tendable: w, facet: "policy_analysis", context: crs,
                                    proposed_key: "affected_states", status: "pending")

    row = Enliterator::Heartbeat.beat!(budget: 10_000) # consider runs

    expect(row.error).to be_nil
    expect(row).to be_finished
    expect(row.warnings.join).to match(/bedrock unavailable/i)
  end

  it "the top-level net: a lapse from any phase finishes clean, never fatal" do
    configure!(LapseStubLLM.new)
    seed_history!
    widget!("ok")
    allow_any_instance_of(Enliterator::Heartbeat)
      .to receive(:work_items!).and_raise(RuntimeError.new(LAPSE_MSG))

    expect {
      @row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
    }.not_to raise_error

    expect(@row.error).to be_nil
    expect(@row).to be_finished
    expect(@row.warnings.join).to match(/bedrock unavailable/i)
  end

  it "a NON-bedrock failure is still fatal (back-compat — only bedrock is graceful)" do
    configure!(LapseStubLLM.new)
    seed_history!
    6.times { |i| widget!("boom-#{i}") }

    expect {
      Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
    }.to raise_error(/all failed/)

    row = Enliterator::Heartbeat.order(:id).last
    expect(row.error).to match(/all failed/)
  end

  it "DEFERS a bedrock TIMEOUT too (id=56's mode) — no abort, clean finish" do
    configure!(LapseStubLLM.new)
    seed_history!
    6.times { |i| widget!("timeout-#{i}") }

    expect {
      @row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
    }.not_to raise_error

    expect(@row.error).to be_nil
    expect(@row).to be_finished
    expect(@row.executed.dig("frontier", "deferred")).to eq(6)
    expect(@row.executed.dig("frontier", "failed").to_i).to eq(0)
    expect(@row.warnings.join).to match(/bedrock unavailable/i)
  end

  it "holds a considerer scope that TIMES OUT and finishes the cycle clean" do
    llm = LapseStubLLM.new
    llm.decide_times_out = true
    configure!(llm)
    w = seed_history!
    Enliterator::Suggestion.create!(tendable: w, facet: "policy_analysis", context: crs,
                                    proposed_key: "affected_states", status: "pending")

    row = Enliterator::Heartbeat.beat!(budget: 10_000) # consider runs

    expect(row.error).to be_nil
    expect(row).to be_finished
    expect(row.warnings.join).to match(/bedrock unavailable/i)
  end
end
