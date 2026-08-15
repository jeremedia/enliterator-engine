# frozen_string_literal: true

require "rails_helper"

# v0.71 — WHO KNOWS WHY THE FACT IS MISSING.
#
# v0.46.1 asks the model to diagnose an unmet required term: `defective_surrogate`
# (the item HAS the fact, extraction lost it) vs `silent` (the item omits it; an
# authority may know). The model cannot actually answer that question. It is shown
# the SURROGATE, never the item, so when extraction has failed it truthfully reports
# that the text it was given is silent — and is wrong about the item, which has a
# byline on its title page.
#
# Measured on a live collection: 26 of 31 open `authored_by` lacunae were diagnosed
# `silent` on records whose extracted text was EMPTY. 84%, and systematically — not
# a model quality problem, a question the model was never in a position to answer.
#
# The engine is. A condition probe already knows the extraction failed. v0.71 lets a
# probe say so, and the visitor believes the probe over the reader.
RSpec.describe "v0.71 condition-informed lacuna diagnosis" do
  let(:widget)   { Widget.create!(title: "T", body: "b") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # Returns no claim for the required term, and diagnoses the absence as `silent`
  # — exactly what a reader shown a truncated surrogate reports.
  class SilentDiagnosisStub
    Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
    def model_id = "stub"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      Result.new(parsed: {
        "claims" => [],
        "confidence" => 0.9,
        "absences" => [ { "term" => "authored_by", "diagnosis" => "silent",
                          "note" => "the text does not name an author" } ]
      }, raw: {}, tokens: {})
    end
  end

  def staff!
    Enliterator.configure do |c|
      c.record_lacunae = true
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :authorship, tier: "cheap", required: [ :authored_by ],
              terms: { authored_by: "Who wrote it." }
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(SilentDiagnosisStub.new)
  end

  def tend!
    Enliterator::Tending::Visitor.new(widget, facet: "authorship", embedder: embedder).call
  end

  def lacuna = widget.enliterator_lacunae.open.find_by(key: "authored_by")

  around do |ex|
    prior_lac = Enliterator.configuration.record_lacunae
    Enliterator::Condition.reset_registry!
    ex.run
    Enliterator::Condition.reset_registry!
    Enliterator.configuration.record_lacunae = prior_lac
  end

  context "when NO probe claims to detect a defective surrogate (the default)" do
    it "keeps the model's diagnosis — byte-identical to v0.46.1" do
      staff!
      tend!
      expect(lacuna.diagnosis).to eq("silent")
    end

    # The guarantee is that an unadopting host pays NOTHING — not that the check is
    # never reached. `surrogate_defective?` short-circuits on the empty registry, so
    # what must be pinned is the absence of a QUERY, which is the cost.
    it "runs a tend without querying condition measures" do
      staff!
      queried = false
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queried = true if payload[:sql].to_s.include?("enliterator_measures") &&
                          payload[:sql].to_s.match?(/condition_/)
      end
      tend!
      ActiveSupport::Notifications.unsubscribe(sub)
      expect(queried).to be(false)
    end
  end

  context "when a defective-surrogate probe is FAILING for this record" do
    before do
      Enliterator::Condition.register(:extraction, defective_surrogate: true) do |_r|
        { ok: false, code: "extract_error", note: "no text extracted" }
      end
      Enliterator::Condition.survey!(widget)
      staff!
    end

    it "overrides the reader: the engine knows extraction failed, the reader cannot" do
      tend!
      expect(lacuna.diagnosis).to eq("defective_surrogate")
    end

    it "RECORDS the override rather than silently replacing the reader's answer" do
      tend!
      expect(lacuna.note).to include("silent")      # what the reader said
      expect(lacuna.note).to match(/extraction/i)   # which probe overruled it
    end
  end

  context "when a defective-surrogate probe is PASSING for this record" do
    before do
      Enliterator::Condition.register(:extraction, defective_surrogate: true) do |_r|
        { ok: true }
      end
      Enliterator::Condition.survey!(widget)
      staff!
    end

    it "leaves the model's diagnosis alone — a healthy surrogate means `silent` may be true" do
      tend!
      expect(lacuna.diagnosis).to eq("silent")
    end
  end

  describe "Condition.surrogate_defective?" do
    it "is false when the registry declares no such probe, without touching the DB" do
      expect(Enliterator::Measure).not_to receive(:where)
      expect(Enliterator::Condition.surrogate_defective?(widget)).to be(false)
    end

    it "ignores a FAILING probe that did not declare the flag" do
      Enliterator::Condition.register(:linkrot) { |_r| { ok: false, code: "dead" } }
      Enliterator::Condition.survey!(widget)
      expect(Enliterator::Condition.surrogate_defective?(widget)).to be(false)
    end
  end
end
