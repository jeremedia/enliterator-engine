# frozen_string_literal: true

require "rails_helper"

# v0.58 — the grounded golden-set generator. The model only phrases; keys stay
# grounded in the record's surrogate/claims; a mechanical check flags leakage.
RSpec.describe Enliterator::FirstImpression::Generator do
  let(:record) { double("rec", enliterator_text: "This studies arson threats to federal buildings.") }
  let(:claims) { [ double(key: "key_findings", value: "the standard is deficient") ] }

  # A stub whose #decide returns a canned question set regardless of input.
  def stub_llm(questions)
    Class.new do
      define_method(:model_id) { "stub-quality" }
      define_method(:decide) { |messages:, schema:, tool_name:, tags: []| { "questions" => questions } }
    end.new
  end

  it "annotates questions with the deep flag and a grounding verdict" do
    llm = stub_llm([
      { "id" => "a1", "type" => "reading",  "question" => "Topic?", "ideal" => "arson threats to federal buildings", "source" => "surrogate" },
      { "id" => "b1", "type" => "coverage", "question" => "Author?", "ideal" => "Robert A. Neale", "source" => "authored_by" },
      { "id" => "b2", "type" => "coverage", "question" => "Finding?", "ideal" => "the fire modeling shows sprinklers work", "source" => "key_findings" }
    ])
    qs = described_class.new(llm: llm).generate(record, claims: claims)
    b2 = qs.find { |q| q["id"] == "b2" }
    expect(b2["deep"]).to be(true)          # key_findings is an analytical facet
    expect(qs.find { |q| q["id"] == "b1" }["deep"]).to be(false)
    expect(qs.map { |q| q["grounding"] }).to all(eq("ok"))
  end

  it "flags a coverage key whose answer actually appears in the surrogate" do
    llm = stub_llm([
      { "id" => "b1", "type" => "coverage", "question" => "About?", "ideal" => "arson threats to federal buildings", "source" => "summary" }
    ])
    qs = described_class.new(llm: llm).generate(record, claims: claims)
    expect(qs.first["grounding"]).to match(/coverage key appears in surrogate/)
  end

  it "raises on the Null adapter rather than faking a result" do
    expect { described_class.new(llm: Enliterator::Adapters::LLM::Null.new).generate(record, claims: claims) }
      .to raise_error(Enliterator::FirstImpression::NullAdapterError)
  end
end
