# frozen_string_literal: true

require "rails_helper"

# v0.46.1 — Bedrock-class parity. The Bedrock class is unused in production (HSDL
# routes through the Gateway), but parity keeps it correct: it must accept `required:`,
# thread it into system_for/schema_for (so it honors the v0.5 REQUIRED block + the
# v0.46.1 absences schema), and pass BOTH suggestions and absences through extract_parsed
# (it dropped suggestions entirely before — a pre-existing gap this closes). Flag off /
# no contract → input_schema.json == RESPONSE_SCHEMA (golden stays green).
RSpec.describe "Enliterator::Adapters::LLM::Bedrock parity (v0.46.1)" do
  # Converse-shaped fake whose tool_use input is fully configurable (so we can return
  # suggestions/absences) and which records the converse kwargs (so we can read the
  # bound input_schema).
  class AbsConverseClient
    attr_reader :last_kwargs
    def initialize(input:) = @input = input
    def converse(**kwargs)
      @last_kwargs = kwargs
      { output: { message: { role: "assistant",
        content: [ { tool_use: { name: Enliterator::Adapters::LLM::Base::TOOL_NAME, input: @input } } ] } },
        usage: { input_tokens: 5, output_tokens: 1, total_tokens: 6 }, stop_reason: "tool_use" }
    end
  end

  let(:contract) { { "authored_by" => "The author(s).", "advisor" => "The advisor(s)." } }
  let(:required) { [ "authored_by" ] }

  def client_for(input) = AbsConverseClient.new(input: input)
  def adapter_for(client) = described_class_bedrock.new(model_id: "anthropic.claude-x", client: client)
  def described_class_bedrock = Enliterator::Adapters::LLM::Bedrock

  def tend!(adapter, contract: nil, required: nil)
    adapter.tend(text: "doc", facet: "authorship", state: {}, neighbors: [],
                 contract: contract, required: required)
  end

  def bound_schema(client) = client.last_kwargs.dig(:tool_config, :tools, 0, :tool_spec, :input_schema, :json)

  describe "tend accepts required: and threads it into the schema" do
    let(:input) { { "claims" => [], "confidence" => 0.5 } }

    it "does not raise on a required: kwarg" do
      expect { tend!(adapter_for(client_for(input)), contract: contract, required: required) }.not_to raise_error
    end

    it "binds an absences-bearing schema when record_lacunae is on" do
      Enliterator.configure { |c| c.record_lacunae = true }
      client = client_for(input)
      tend!(adapter_for(client), contract: contract, required: required)
      expect(bound_schema(client)["properties"]).to have_key("absences")
    end

    it "binds RESPONSE_SCHEMA verbatim for an unconstrained facet" do
      client = client_for(input)
      tend!(adapter_for(client))
      expect(bound_schema(client)).to eq(Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA)
    end

    it "binds a contract schema WITHOUT absences when the flag is off (parity pin)" do
      client = client_for(input)
      tend!(adapter_for(client), contract: contract, required: required)
      props = bound_schema(client)["properties"]
      expect(props).to have_key("suggestions") # contract path always carries suggestions
      expect(props).not_to have_key("absences") # but not absences when the flag is off
    end
  end

  describe "extract_parsed surfaces both suggestions and absences (closes the suggestions drop)" do
    let(:input) do
      {
        "claims" => [ { "key" => "advisor", "value" => "Dr. A", "confidence" => 0.8, "op" => "ADD" } ],
        "confidence" => 0.6,
        "suggestions" => [ { "proposed_key" => "funding_source", "rationale" => "names the funder" } ],
        "absences" => [ { "term" => "authored_by", "diagnosis" => "defective_surrogate", "note" => "byline dropped" } ]
      }
    end

    it "passes suggestions through" do
      result = tend!(adapter_for(client_for(input)), contract: contract, required: required)
      expect(result.parsed["suggestions"]).to eq(
        [ { "proposed_key" => "funding_source", "rationale" => "names the funder" } ]
      )
    end

    it "passes absences through, normalized" do
      result = tend!(adapter_for(client_for(input)), contract: contract, required: required)
      expect(result.parsed["absences"]).to eq(
        [ { "term" => "authored_by", "diagnosis" => "defective_surrogate", "note" => "byline dropped" } ]
      )
    end
  end
end
