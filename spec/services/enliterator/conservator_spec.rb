# frozen_string_literal: true

require "rails_helper"

# v0.17 — the conservator: one agent call over the failure piles, writing
# diagnosis + treatment per pile, keyed by signature via positional ids.
RSpec.describe Enliterator::Conservator do
  class ConservatorStub
    attr_reader :decide_calls, :last_messages
    def initialize(treatments: nil) = (@treatments = treatments; @decide_calls = 0)
    def model_id = "stub-quality"
    def decide(messages:, schema:, tool_name:, tags: [])
      @decide_calls += 1
      @last_messages = messages
      { "treatments" => @treatments || [] }
    end
  end

  def condemn!(title, code: "no_text")
    Enliterator::Condition.register(:legibility, gates_tending: true) do |r|
      { ok: r.body.present?, code: code, note: "no usable text",
        remediation: "upload the PDF or supply a replacement URL" }
    end unless Enliterator::Condition.probes_registered?
    w = Widget.create!(title: title, body: nil)
    Enliterator::Condition.survey!(w)
    w
  end

  it "writes diagnosis + treatment for each pile, keyed back by positional id" do
    condemn!("dead one")
    condemn!("dead two")
    stub = ConservatorStub.new(treatments: [
      { "id" => "s1", "diagnosis" => "These records carry no extractable text.",
        "treatment" => "Per the stated remediation: upload PDFs.", "confidence" => 0.9 }
    ])

    summary = described_class.new(llm: stub).assess!
    expect(summary[:diagnosed]).to eq(1)

    row = Enliterator::Treatment.find_by(signature: "legibility:no_text")
    expect(row.diagnosis).to include("no extractable text")
    expect(row.last_seen_count).to eq(2)
    expect(row.rung).to eq(1)
    expect(row.sample.size).to eq(2)
    expect(row.model).to eq("stub-quality")
  end

  it "feeds the probe's remediation into the prompt as ground truth, with sample titles" do
    condemn!("A Famous Thesis")
    stub = ConservatorStub.new
    described_class.new(llm: stub).assess!

    prompt = stub.last_messages.last[:content]
    expect(prompt).to include("upload the PDF or supply a replacement URL")
    expect(prompt).to include("A Famous Thesis")
    expect(stub.last_messages.first[:content]).to include("NEVER invent procedures")
  end

  it "delta-gates: an unchanged field skips the LLM entirely (sightings still recorded)" do
    condemn!("dead")
    stub = ConservatorStub.new
    conservator = described_class.new(llm: stub)
    conservator.assess!
    summary = conservator.assess!

    expect(stub.decide_calls).to eq(1)
    expect(summary[:skipped]).to include("unchanged")
    expect(Enliterator::Treatment.find_by(signature: "legibility:no_text").last_seen_at)
      .to be_present
  end

  it "a grown pile re-opens the case" do
    condemn!("dead one")
    stub = ConservatorStub.new
    conservator = described_class.new(llm: stub)
    conservator.assess!
    condemn!("dead two")
    conservator.assess!
    expect(stub.decide_calls).to eq(2)
  end

  it "includes the rung-4 residue as a synthetic pile, partitioned in the prompt" do
    Enliterator::Condition.register(:legibility, gates_tending: true) { |_r| { ok: true } }
    lost = Widget.create!(title: "read but opaque", body: "b")
    2.times do |i|
      lost.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true,
                                      tier: "cheap", created_at: (3 - i).days.ago,
                                      started_at: (3 - i).days.ago)
    end
    Enliterator::Condition.survey!(lost)

    stub = ConservatorStub.new
    described_class.new(llm: stub).assess!
    prompt = stub.last_messages.last[:content]
    expect(prompt).to include("TENDING-QUALITY")
    expect(Enliterator::Treatment.find_by(signature: "rung4:never_understood").last_seen_count).to eq(1)
  end

  it "an unissued id from the model is dropped, never guessed" do
    condemn!("dead")
    stub = ConservatorStub.new(treatments: [
      { "id" => "s99", "diagnosis" => "phantom", "treatment" => "x", "confidence" => 1.0 }
    ])
    summary = described_class.new(llm: stub).assess!
    expect(summary[:diagnosed]).to eq(0)
    expect(Enliterator::Treatment.find_by(signature: "legibility:no_text").diagnosis).to be_nil
  end

  it "soft-degrades without an LLM: sightings recorded, diagnoses deferred, no raise" do
    condemn!("dead")
    summary = described_class.new.assess!   # resolves to the Null adapter
    expect(summary[:skipped]).to include("no LLM")
    expect(Enliterator::Treatment.find_by(signature: "legibility:no_text")).to be_present
  end

  it "a clean shelf is a logged no-op" do
    expect(described_class.new(llm: ConservatorStub.new).assess![:skipped]).to include("clean")
  end
end
