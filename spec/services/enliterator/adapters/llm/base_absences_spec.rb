# frozen_string_literal: true

require "rails_helper"

# v0.46.1 — the ABSENCES diagnosis channel. When a facet has REQUIRED terms AND
# config.record_lacunae is on, schema_for attaches an optional top-level `absences`
# array (the model's sanctioned channel to diagnose a required term it cannot fill)
# and contract_system_block SWAPS the v0.5 "assert an empty value" sentence for the
# absences instruction. Both are gated: with the flag off the schema and prompt are
# byte-identical to v0.46 (rule 1). Mirrors the suggestions-channel pattern, exercised
# through the Null adapter which inherits schema_for/system_for from Base.
RSpec.describe "Enliterator::Adapters::LLM::Base absences channel (v0.46.1)" do
  let(:adapter)  { Enliterator::Adapters::LLM::Null.new }
  let(:contract) { { "authored_by" => "The author(s).", "advisor" => "The advisor(s)." } }
  let(:required) { [ "authored_by" ] }

  def flag_on!  = Enliterator.configure { |c| c.record_lacunae = true }

  describe "#schema_for" do
    context "flag ON, contract with required terms" do
      before { flag_on! }

      it "attaches an OPTIONAL top-level absences array with a diagnosis enum" do
        schema = adapter.schema_for(contract, required: required)
        expect(schema["properties"]).to have_key("absences")
        expect(schema.dig("properties", "absences", "type")).to eq("array")
        # absences stays OPTIONAL — never added to top-level required.
        expect(schema["required"]).not_to include("absences")
        item_required = schema.dig("properties", "absences", "items", "required")
        expect(item_required).to include("term", "diagnosis")
        diag_enum = schema.dig("properties", "absences", "items", "properties", "diagnosis", "enum")
        expect(diag_enum).to match_array(%w[defective_surrogate silent not_identified])
        # the engine-only no-info default is NEVER offered to the model
        expect(diag_enum).not_to include("undiagnosed")
      end

      it "still carries the suggestions array (absences is additive, not a replacement)" do
        schema = adapter.schema_for(contract, required: required)
        expect(schema["properties"]).to have_key("suggestions")
      end

      it "does NOT mutate the shared RESPONSE_SCHEMA constant" do
        adapter.schema_for(contract, required: required)
        const = Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA
        expect(const["properties"]).not_to have_key("absences")
        expect(const["properties"]).not_to have_key("suggestions")
      end

      it "adds NO absences when the facet has no required terms" do
        expect(adapter.schema_for(contract, required: nil)["properties"]).not_to have_key("absences")
        expect(adapter.schema_for(contract, required: [])["properties"]).not_to have_key("absences")
      end

      it "returns RESPONSE_SCHEMA verbatim for an unconstrained facet (absences needs a contract)" do
        expect(adapter.schema_for(nil, required: required))
          .to eq(Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA)
      end
    end

    context "flag OFF (byte-identical to v0.46)" do
      it "adds NO absences even when required terms are present" do
        schema = adapter.schema_for(contract, required: required)
        expect(schema["properties"]).not_to have_key("absences")
      end

      it "is byte-identical to the no-required schema" do
        expect(adapter.schema_for(contract, required: required)).to eq(adapter.schema_for(contract))
      end
    end
  end

  describe "#system_for / the REQUIRED prompt block" do
    context "flag ON, required terms present" do
      before { flag_on! }

      it "instructs routing unmet terms to absences and names the three diagnoses" do
        sys = adapter.system_for(contract, required: required)
        expect(sys).to match(/absences/i)
        expect(sys).to include("defective_surrogate", "silent", "not_identified")
      end

      it "REPLACES the v0.5 empty-value instruction (no self-contradiction)" do
        sys = adapter.system_for(contract, required: required)
        # the prompt wraps across lines, so tolerate "empty\nvalue"
        expect(sys).not_to match(/empty\s+value/i)
      end
    end

    context "flag OFF (byte-identical to v0.46)" do
      it "keeps the v0.5 empty-value instruction and never mentions absences" do
        sys = adapter.system_for(contract, required: required)
        expect(sys).to match(/empty\s+value/i)
        expect(sys).not_to match(/absences/i)
      end
    end
  end
end
