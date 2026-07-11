# frozen_string_literal: true

require "rails_helper"

# v0.58 — the first-impression diagnostic, end to end. One stub adapter drives all
# three LLM steps (generate / answer / judge), dispatching on tool_name, and
# SIMULATES the real arm difference: the coverage answer is reachable only when the
# arm's context contains the claim (manual), so manual out-covers the bare surrogate.
RSpec.describe Enliterator::FirstImpression do
  # A Widget with a thin surrogate + two understanding claims (human-attributed so
  # they land in Claim.live.understanding). The key finding is NOT in the surrogate.
  let!(:widget) do
    w = Widget.create!(title: "Arson Study", body: "This studies arson threats to federal buildings.")
    w.assert_claim!(key: "authored_by", value: "Ada Lovelace", attributed_to: "human:test")
    w.assert_claim!(key: "key_findings", value: "the standard is deficient", attributed_to: "human:test")
    w
  end

  # Fixed golden set the stub generates; the answer/judge steps reference it.
  let(:stub) do
    Class.new do
      def golden_set
        [ { "id" => "a1", "type" => "reading",  "question" => "What does the study examine?", "ideal" => "arson threats" },
          { "id" => "b1", "type" => "coverage", "question" => "What is the key finding?", "ideal" => "the standard is deficient", "source" => "key_findings" },
          { "id" => "c1", "type" => "trap",     "question" => "What is the budget?", "ideal" => "not addressed" } ]
      end

      def model_id = "stub-quality"

      def decide(messages:, schema:, tool_name:, tags: [])
        content = messages.last[:content].to_s
        case tool_name
        when "emit_questions" then { "questions" => golden_set }
        when "emit_answers"   then answer(content)
        when "emit_verdicts"  then judge(content)
        end
      end

      # The answerer reads the arm's SOURCE: it can only answer the coverage question
      # when the finding is present (i.e. the manual arm's enliteration).
      def answer(source)
        answers = [
          { "id" => "a1", "answer" => "arson threats", "confidence" => 0.9 },
          { "id" => "c1", "answer" => "not in the source", "confidence" => 0.9 }
        ]
        answers << if source.include?("deficient")
          { "id" => "b1", "answer" => "the standard is deficient", "confidence" => 0.9 }
        else
          { "id" => "b1", "answer" => "not in the source", "confidence" => 0.8 }
        end
        { "first_expression" => "An abstract about arson.", "answers" => answers }
      end

      def judge(content)
        items = JSON.parse(content[/\[.*\]/m])
        verdicts = items.map do |it|
          abstained = it["response"].to_s.match?(/not in the source|not addressed/i)
          correct = if it["type"] == "trap" then (abstained ? 1.0 : 0.0)
                    elsif abstained then 0.0 else 1.0 end
          { "id" => it["id"], "correct" => correct, "abstained" => abstained, "fabricated" => false }
        end
        { "fe_rich" => 1.0, "verdicts" => verdicts }
      end
    end.new
  end

  it "runs generate -> arms -> answer -> judge -> report and shows the coverage lift" do
    report = described_class.run(context: nil, sample: 1, tiers: [ "quality" ], reps: 1, llm: stub)

    expect(report["n_records"]).to eq(1)
    expect(report["arms"]).to contain_exactly("no_map", "map", "manual")
    # manual has the finding in context and answers it; the bare arms cannot.
    expect(report["per_arm"]["manual"]["coverage"][0]).to eq(1.0)
    expect(report["per_arm"]["no_map"]["coverage"][0]).to eq(0.0)
    expect(report["per_arm"]["map"]["coverage"][0]).to eq(0.0)
    expect(report["headline"]["coverage_lift"]).to eq(1.0)
    # reading is answerable from the surrogate in every arm — the confound canary.
    expect(report["headline"]["reading_flat"]).to be(true)
  end

  it "adds the fulltext arm when the host provides a full-source hook" do
    allow(Enliterator.configuration).to receive(:first_impression_full_text)
      .and_return(->(_rec) { "a much longer full body of the source " * 20 })
    report = described_class.run(context: nil, sample: 1, tiers: [ "quality" ], reps: 1, llm: stub)
    expect(report["arms"]).to include("fulltext")
  end

  it "raises on the Null adapter rather than producing a fake report" do
    expect { described_class.run(context: nil, sample: 1, llm: Enliterator::Adapters::LLM::Null.new) }
      .to raise_error(Enliterator::FirstImpression::NullAdapterError)
  end
end
