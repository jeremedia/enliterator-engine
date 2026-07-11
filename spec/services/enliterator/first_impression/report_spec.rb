# frozen_string_literal: true

require "rails_helper"

# v0.58 — pure metric aggregation for the first-impression diagnostic.
RSpec.describe Enliterator::FirstImpression::Report do
  R = Enliterator::FirstImpression::Report::Run unless defined?(R)

  # A 4-question golden set: 1 reading, 1 coverage (deep), 1 coverage (shallow), 1 trap.
  let(:golden) do
    { "a1" => { "type" => "reading" },
      "b1" => { "type" => "coverage", "deep" => true },
      "b2" => { "type" => "coverage", "deep" => false },
      "c1" => { "type" => "trap" } }
  end

  def run(arm:, tier: "quality", record: "r1", correct:, conf:, fab: {}, fe: 1.0, tokens: 1000)
    verdicts = correct.to_h { |id, c| [ id, { "correct" => c, "fabricated" => fab.fetch(id, false) } ] }
    R.new(arm: arm, tier: tier, record: record, golden: golden, confidences: conf,
          verdicts: verdicts, fe_rich: fe, tokens: tokens)
  end

  describe ".metrics_for_run" do
    it "averages correct by question type and computes Brier from confidence vs correct" do
      r = run(arm: "manual",
              correct: { "a1" => 1.0, "b1" => 1.0, "b2" => 1.0, "c1" => 1.0 },
              conf:    { "a1" => 1.0, "b1" => 1.0, "b2" => 1.0, "c1" => 1.0 })
      m = described_class.metrics_for_run(r)
      expect(m["reading"]).to eq(1.0)
      expect(m["coverage"]).to eq(1.0)
      expect(m["deep"]).to eq(1.0)     # only b1
      expect(m["brier"]).to eq(0.0)    # perfectly calibrated
    end

    it "penalizes confident wrong answers in Brier and counts fabrication on traps" do
      r = run(arm: "no_map",
              correct: { "a1" => 1.0, "b1" => 0.0, "b2" => 0.0, "c1" => 0.0 },
              conf:    { "a1" => 1.0, "b1" => 1.0, "b2" => 1.0, "c1" => 1.0 },
              fab:     { "c1" => true })
      m = described_class.metrics_for_run(r)
      expect(m["coverage"]).to eq(0.0)
      expect(m["brier"]).to be > 0.5          # confident + wrong on 3 of 4
      expect(m["fabrication"]).to eq(0.333)   # 1 of {b1,b2,c1} fabricated (c1) → 1/3
    end
  end

  describe ".build" do
    let(:runs) do
      [
        run(arm: "manual", record: "r1", correct: { "a1"=>1.0,"b1"=>1.0,"b2"=>1.0,"c1"=>1.0 }, conf: { "a1"=>0.9,"b1"=>0.9,"b2"=>0.9,"c1"=>0.9 }),
        run(arm: "manual", record: "r2", correct: { "a1"=>1.0,"b1"=>1.0,"b2"=>1.0,"c1"=>1.0 }, conf: { "a1"=>0.9,"b1"=>0.9,"b2"=>0.9,"c1"=>0.9 }),
        run(arm: "no_map", record: "r1", correct: { "a1"=>1.0,"b1"=>0.0,"b2"=>0.0,"c1"=>1.0 }, conf: { "a1"=>0.9,"b1"=>0.5,"b2"=>0.5,"c1"=>0.9 }),
        run(arm: "no_map", record: "r2", correct: { "a1"=>1.0,"b1"=>0.0,"b2"=>0.0,"c1"=>1.0 }, conf: { "a1"=>0.9,"b1"=>0.5,"b2"=>0.5,"c1"=>0.9 })
      ]
    end

    it "aggregates per arm and computes the coverage lift headline" do
      rep = described_class.build(runs)
      expect(rep["n_records"]).to eq(2)
      expect(rep["per_arm"]["manual"]["coverage"][0]).to eq(1.0)
      expect(rep["per_arm"]["no_map"]["coverage"][0]).to eq(0.0)
      expect(rep["headline"]["coverage_lift"]).to eq(1.0)
    end

    it "flags the reading canary as flat when reading accuracy matches across arms" do
      rep = described_class.build(runs)
      expect(rep["reading_canary"]["manual"]).to eq(1.0)
      expect(rep["reading_canary"]["no_map"]).to eq(1.0)
      expect(rep["headline"]["reading_flat"]).to be(true)
    end

    it "reports a canary breach when reading accuracy diverges across arms" do
      leaky = runs + [ run(arm: "map", correct: { "a1"=>0.0,"b1"=>0.0,"b2"=>0.0,"c1"=>0.0 },
                           conf: { "a1"=>0.5,"b1"=>0.5,"b2"=>0.5,"c1"=>0.5 }) ]
      expect(described_class.build(leaky)["headline"]["reading_flat"]).to be(false)
    end
  end
end
