# frozen_string_literal: true

require "rails_helper"

# v0.58 — the blind judge. Grades answers against the golden key with no arm label
# in the prompt; parses correct/abstained/fabricated + fe_rich.
RSpec.describe Enliterator::FirstImpression::Judge do
  let(:golden) do
    [ { "id" => "a1", "type" => "reading",  "question" => "Topic?",  "ideal" => "arson" },
      { "id" => "b1", "type" => "coverage", "question" => "Author?", "ideal" => "Neale" } ]
  end

  # A capturing stub: records the prompt and returns canned verdicts.
  let(:stub) do
    Class.new do
      attr_reader :last_messages
      def model_id = "stub-quality"
      def decide(messages:, schema:, tool_name:, tags: [])
        @last_messages = messages
        { "fe_rich" => 1.0, "verdicts" => [
          { "id" => "a1", "correct" => 1.0, "abstained" => false, "fabricated" => false },
          { "id" => "b1", "correct" => 0.0, "abstained" => true,  "fabricated" => false }
        ] }
      end
    end.new
  end

  it "parses verdicts and fe_rich into the report shape" do
    out = described_class.new(llm: stub).judge(
      golden: golden, answers: { "a1" => "arson", "b1" => "not in the source" }, first_expression: "An abstract."
    )
    expect(out["fe_rich"]).to eq(1.0)
    expect(out["verdicts"]["a1"]).to eq({ "correct" => 1.0, "abstained" => false, "fabricated" => false })
    expect(out["verdicts"]["b1"]["abstained"]).to be(true)
  end

  it "is blind — no arm label reaches the judge prompt" do
    described_class.new(llm: stub).judge(golden: golden, answers: { "a1" => "arson" }, first_expression: "x")
    prompt = stub.last_messages.map { |m| m[:content] }.join
    expect(prompt).not_to match(/no_map|manual|fulltext|\barm\b/i)
  end

  it "raises on the Null adapter" do
    expect { described_class.new(llm: Enliterator::Adapters::LLM::Null.new).judge(golden: golden, answers: {}, first_expression: "x") }
      .to raise_error(Enliterator::FirstImpression::NullAdapterError)
  end
end
