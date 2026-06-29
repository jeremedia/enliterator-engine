require "rails_helper"

# Bedrock adapter contract — NO real AWS. We inject a fake client responding to
# #converse with a Converse-shaped tool-use block carrying an emit_claims payload
# and a usage block. The spec asserts #tend parses claims + tokens, and that the
# adapter forces structured output by binding the single emit_claims tool to
# RESPONSE_SCHEMA with tool_choice. Live Bedrock is validated by the host once
# AWS creds exist; the injected client means no provider gem is required here.
RSpec.describe Enliterator::Adapters::LLM::Bedrock do
  # Hand-rolled fake standing in for Aws::BedrockRuntime::Client. It records the
  # kwargs it was called with (so we can assert the forced-tool wiring) and
  # returns a canned Converse-shaped response built from `claims`/`usage`.
  #
  # The response is plain nested hashes with symbol keys — the adapter's
  # dig_content / tool_use_of / extract_tokens all handle the Hash shape, so no
  # AWS SDK structs (and thus no aws-sdk-bedrockruntime gem) are needed.
  class FakeConverseClient
    attr_reader :last_kwargs

    def initialize(claims:, usage:, confidence: 0.83)
      @claims     = claims
      @usage      = usage
      @confidence = confidence
    end

    def converse(**kwargs)
      @last_kwargs = kwargs
      {
        output: {
          message: {
            role: "assistant",
            content: [
              {
                tool_use: {
                  name:  Enliterator::Adapters::LLM::Base::TOOL_NAME,
                  input: { "claims" => @claims, "confidence" => @confidence }
                }
              }
            ]
          }
        },
        usage: @usage,
        stop_reason: "tool_use"
      }
    end
  end

  let(:claims_payload) do
    [
      { "key" => "summary",     "value" => "A concise account.",   "confidence" => 0.9, "op" => "ADD" },
      { "key" => "authored_by", "value" => "Ada Lovelace",          "confidence" => 0.7, "op" => "UPDATE" }
    ]
  end

  let(:usage_payload) do
    { input_tokens: 1200, output_tokens: 64, total_tokens: 1264 }
  end

  let(:fake_client) do
    FakeConverseClient.new(claims: claims_payload, usage: usage_payload)
  end

  let(:adapter) do
    described_class.new(model_id: "anthropic.claude-3-5-sonnet-20241022-v2:0", client: fake_client)
  end

  let(:result) do
    adapter.tend(
      text:      "Notes on the Analytical Engine.",
      facet:    "summary",
      state:     { claims: [], recent_visits: [], measures: {} },
      neighbors: []
    )
  end

  it "is a kind of LLM::Base" do
    expect(adapter).to be_a(Enliterator::Adapters::LLM::Base)
  end

  describe "#model_id" do
    it "reports the host-supplied model id (never hardcoded)" do
      expect(adapter.model_id).to eq("anthropic.claude-3-5-sonnet-20241022-v2:0")
    end
  end

  describe "#tend (no real AWS — injected fake #converse client)" do
    it "returns a Base::Result" do
      expect(result).to be_a(Enliterator::Adapters::LLM::Base::Result)
    end

    it "parses the tool-use block into the {claims, confidence} shape" do
      expect(result.parsed["confidence"]).to eq(0.83)
      expect(result.parsed["claims"].length).to eq(2)
    end

    it "normalizes each parsed claim to key/value/confidence/op" do
      first = result.parsed["claims"].first
      expect(first).to eq(
        "key"        => "summary",
        "value"      => "A concise account.",
        "confidence" => 0.9,
        "op"         => "ADD"
      )

      second = result.parsed["claims"].last
      expect(second["key"]).to eq("authored_by")
      expect(second["op"]).to eq("UPDATE")
      expect(second["value"]).to eq("Ada Lovelace")
    end

    it "maps Converse usage into the tokens hash" do
      expect(result.tokens).to eq(
        "input"  => 1200,
        "output" => 64,
        "total"  => 1264
      )
    end

    it "captures the raw response for the Visit row" do
      expect(result.raw).to be_a(Hash)
      expect(result.raw[:stop_reason]).to eq("tool_use")
    end

    it "forces structured output: binds the single emit_claims tool to RESPONSE_SCHEMA" do
      result # trigger the converse call
      kwargs = fake_client.last_kwargs

      expect(kwargs[:model_id]).to eq("anthropic.claude-3-5-sonnet-20241022-v2:0")

      tools = kwargs.dig(:tool_config, :tools)
      expect(tools.length).to eq(1)

      spec = tools.first[:tool_spec]
      expect(spec[:name]).to eq(Enliterator::Adapters::LLM::Base::TOOL_NAME)
      expect(spec.dig(:input_schema, :json)).to eq(Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA)

      # tool_choice pins the model to that one tool, compelling a structured emit.
      expect(kwargs.dig(:tool_config, :tool_choice, :tool, :name))
        .to eq(Enliterator::Adapters::LLM::Base::TOOL_NAME)
    end

    it "sends a system instruction and one user message" do
      result
      kwargs = fake_client.last_kwargs

      expect(kwargs[:system]).to be_an(Array)
      expect(kwargs[:system].first[:text]).to be_a(String).and be_present

      expect(kwargs[:messages].length).to eq(1)
      user = kwargs[:messages].first
      expect(user[:role]).to eq("user")
      expect(user[:content].first[:text]).to include("summary")
    end
  end

  describe "tolerance for partial responses" do
    it "yields empty claims + zero confidence when no tool-use block is present" do
      empty_client = Class.new do
        def converse(**)
          { output: { message: { role: "assistant", content: [ { text: "no tool call" } ] } } }
        end
      end.new
      adapter = described_class.new(model_id: "m", client: empty_client)

      parsed = adapter.tend(text: "x", facet: "summary", state: {}, neighbors: []).parsed
      expect(parsed["claims"]).to eq([])
      expect(parsed["confidence"]).to eq(0.0)
    end

    it "returns an empty tokens hash when usage is absent" do
      no_usage_client = FakeConverseClient.new(claims: [], usage: nil)
      adapter = described_class.new(model_id: "m", client: no_usage_client)

      expect(adapter.tend(text: "x", facet: "summary", state: {}, neighbors: []).tokens).to eq({})
    end
  end

  # Parity with Gateway: Bedrock's normalize_claims must also handle a stringified
  # claims array and raise ResponseFormatError on malformed strings.
  describe "stringified claims recovery — parity with Gateway" do
    def adapter_with_claims_input(claims_input)
      client = FakeConverseClient.new(claims: claims_input, usage: usage_payload)
      described_class.new(model_id: "m", client: client)
    end

    it "recovers claims when the model returns them as a valid stringified JSON array" do
      stringified = JSON.generate([
        { "key" => "summary", "value" => "Parity check.", "confidence" => 0.9, "op" => "ADD" }
      ])
      result = adapter_with_claims_input(stringified).tend(
        text: "x", facet: "summary", state: {}, neighbors: []
      )
      expect(result.parsed["claims"].length).to eq(1)
      expect(result.parsed["claims"].first["key"]).to eq("summary")
    end

    it "raises ResponseFormatError on a non-empty malformed stringified claims array" do
      malformed = '[{"key": "summary", "value": "concept of "enliteracy" here", "op": "ADD"}]'
      expect {
        adapter_with_claims_input(malformed).tend(
          text: "x", facet: "summary", state: {}, neighbors: []
        )
      }.to raise_error(Enliterator::Adapters::LLM::ResponseFormatError)
    end

    it "does not raise when claims is genuinely empty (regression guard)" do
      expect {
        result = adapter_with_claims_input([]).tend(
          text: "x", facet: "summary", state: {}, neighbors: []
        )
        expect(result.parsed["claims"]).to eq([])
      }.not_to raise_error
    end

    # Parity: the string "[]" is a legitimate stringified empty array — JSON.parse
    # recovers an Array, so the raise guard must NOT fire. Pins the valid-empty-JSON
    # boundary so a future change to the guard can't start raising on empties.
    it "does not raise when claims is the string \"[]\" (stringified empty array)" do
      expect {
        result = adapter_with_claims_input("[]").tend(
          text: "x", facet: "summary", state: {}, neighbors: []
        )
        expect(result.parsed["claims"]).to eq([])
      }.not_to raise_error
    end
  end
end
