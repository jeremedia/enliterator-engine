# frozen_string_literal: true

require "rails_helper"

# LiteLLM Gateway adapter contract — NO real network, NO openai gem touched.
# We inject a fake OpenAI-compatible client whose chat.completions.create records
# the params it was called with and returns a chat-completion-shaped response with
# a forced tool call carrying emit_claims arguments (a JSON STRING, per the OpenAI
# spec) and a usage block. The spec asserts #tend parses tool_calls into claims +
# tokens, forces the tool_choice, sends the tier as the model id, and routes
# metadata tags through extra_body so the array reaches LiteLLM unmangled.
RSpec.describe Enliterator::Adapters::LLM::Gateway do
  # Records the create kwargs and returns an OpenAI chat-completion-shaped Hash.
  # arguments is a JSON STRING — exactly what the real API returns — so the
  # adapter's parse_arguments must JSON.parse it.
  class FakeChatCompletions
    attr_reader :last_kwargs

    def initialize(arguments_json:, usage:)
      @arguments_json = arguments_json
      @usage          = usage
    end

    def create(**kwargs)
      @last_kwargs = kwargs
      {
        "choices" => [
          {
            "message" => {
              "role" => "assistant",
              "tool_calls" => [
                {
                  "type" => "function",
                  "function" => {
                    "name"      => Enliterator::Adapters::LLM::Base::TOOL_NAME,
                    "arguments" => @arguments_json
                  }
                }
              ]
            }
          }
        ],
        "usage" => @usage
      }
    end
  end

  # Two-level fake: client.chat.completions.create(...)
  class FakeOpenAIClient
    attr_reader :completions

    def initialize(arguments_json:, usage:)
      @completions = FakeChatCompletions.new(arguments_json: arguments_json, usage: usage)
    end

    def chat
      self
    end
  end

  let(:arguments_json) do
    JSON.generate(
      "claims" => [
        { "key" => "summary",     "value" => "A concise account.", "confidence" => 0.9, "op" => "ADD" },
        { "key" => "authored_by", "value" => "Ada Lovelace",        "confidence" => 0.7, "op" => "UPDATE" }
      ],
      "confidence" => 0.83
    )
  end

  let(:usage_payload) do
    { "prompt_tokens" => 1200, "completion_tokens" => 64, "total_tokens" => 1264 }
  end

  let(:fake_client) do
    FakeOpenAIClient.new(arguments_json: arguments_json, usage: usage_payload)
  end

  let(:adapter) do
    described_class.new(
      tier:     "cheap",
      base_url: "https://llm.example.com/v1",
      api_key:  "sk-test-not-real",
      client:   fake_client
    )
  end

  it "is a kind of LLM::Base" do
    expect(adapter).to be_a(Enliterator::Adapters::LLM::Base)
  end

  describe "#model_id" do
    it "is the tier alias (the gateway resolves the provider, not the engine)" do
      expect(adapter.model_id).to eq("cheap")
    end
  end

  describe "#tend (injected fake client — no network)" do
    let(:result) do
      adapter.tend(
        text:      "Notes on the Analytical Engine.",
        facet:    "summary",
        state:     { claims: [], recent_visits: [], measures: {} },
        neighbors: [],
        tags:      %w[enliterator host:dummy facet:summary tier:cheap esc:0]
      )
    end

    it "returns a Base::Result" do
      expect(result).to be_a(Enliterator::Adapters::LLM::Base::Result)
    end

    it "parses tool_calls function.arguments (a JSON string) into the {claims, confidence} shape" do
      expect(result.parsed["confidence"]).to eq(0.83)
      expect(result.parsed["claims"].length).to eq(2)

      first = result.parsed["claims"].first
      expect(first["key"]).to eq("summary")
      expect(first["op"]).to eq("ADD")
      expect(first["value"]).to eq("A concise account.")
    end

    it "maps usage (prompt/completion/total) into the engine token shape" do
      expect(result.tokens).to eq(
        "input"  => 1200,
        "output" => 64,
        "total"  => 1264
      )
    end

    it "sends the tier as the model id" do
      result
      expect(fake_client.completions.last_kwargs[:model]).to eq("cheap")
    end

    it "forces structured output via tool_choice on emit_claims bound to RESPONSE_SCHEMA" do
      result
      kwargs = fake_client.completions.last_kwargs

      tools = kwargs[:tools]
      expect(tools.length).to eq(1)
      fn = tools.first[:function]
      expect(fn[:name]).to eq(Enliterator::Adapters::LLM::Base::TOOL_NAME)
      expect(fn[:parameters]).to eq(Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA)

      expect(kwargs.dig(:tool_choice, :type)).to eq("function")
      expect(kwargs.dig(:tool_choice, :function, :name))
        .to eq(Enliterator::Adapters::LLM::Base::TOOL_NAME)
    end

    it "carries the spend tags as metadata via extra_body (array preserved)" do
      result
      kwargs = fake_client.completions.last_kwargs

      tags = kwargs.dig(:request_options, :extra_body, :metadata, :tags)
      expect(tags).to eq(%w[enliterator host:dummy facet:summary tier:cheap esc:0])
      expect(tags).to be_an(Array)
    end

    it "omits request_options entirely when no tags are passed (v0.1-shaped call)" do
      adapter.tend(
        text:      "x",
        facet:    "summary",
        state:     {},
        neighbors: []
      )
      expect(fake_client.completions.last_kwargs).not_to have_key(:request_options)
    end
  end

  describe "self-escalation flag" do
    let(:fake_client) do
      FakeOpenAIClient.new(
        arguments_json: JSON.generate("claims" => [], "confidence" => 0.5, "escalate" => true),
        usage:          usage_payload
      )
    end

    it "surfaces a parsed escalate flag when the model sets it" do
      result = adapter.tend(text: "x", facet: "summary", state: {}, neighbors: [])
      expect(result.parsed["escalate"]).to be(true)
    end
  end

  # v0.3 §2 — when a contract is passed, the request's tool schema constrains the
  # claim `key` to an enum over the allowed keys AND advertises an optional
  # top-level `suggestions` array, while the system message gains a controlled-
  # vocabulary block. When NO contract is passed the request stays byte-identical
  # to v0.2 (parameters == RESPONSE_SCHEMA, no suggestions, original system text).
  describe "#tend with a facet contract" do
    let(:contract) do
      { author: "Who authored the work.", date: "When the work was created." }
    end

    def request_params!
      adapter.tend(
        text:      "x",
        facet:    "metadata",
        state:     {},
        neighbors: [],
        contract:  contract
      )
      fake_client.completions.last_kwargs
    end

    it "enums the claim key to the contract's allowed keys" do
      params = request_params!
      key_schema = params[:tools].first[:function][:parameters]
                         .dig("properties", "claims", "items", "properties", "key")
      expect(key_schema["enum"]).to contain_exactly("author", "date")
    end

    it "adds an optional top-level suggestions array to the schema" do
      params = request_params!
      schema = params[:tools].first[:function][:parameters]
      expect(schema["properties"]).to have_key("suggestions")
      expect(schema.dig("properties", "suggestions", "type")).to eq("array")
      # suggestions stays OPTIONAL — never added to required.
      expect(schema["required"]).not_to include("suggestions")
      item_required = schema.dig("properties", "suggestions", "items", "required")
      expect(item_required).to include("proposed_key", "rationale")
    end

    it "does NOT mutate the shared RESPONSE_SCHEMA constant" do
      request_params!
      # The constant must remain the open-key, suggestion-free v0.2 schema.
      const = Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA
      expect(const["properties"]).not_to have_key("suggestions")
      expect(const.dig("properties", "claims", "items", "properties", "key"))
        .not_to have_key("enum")
    end

    it "appends a controlled-vocabulary block to the system message" do
      params = request_params!
      system = params[:messages].find { |m| m[:role] == "system" }[:content]
      expect(system).to match(/CONTROLLED VOCABULARY/i)
      expect(system).to include("author")
      expect(system).to include("date")
    end
  end

  describe "#tend with candidates (stage 1 — read-time warrant)" do
    let(:contract)   { { author: "Who authored it.", date: "When." } }
    let(:candidates) { [ { proposed_key: "funder", count: 3, sample_rationale: "names the funder" } ] }

    def system_content
      fake_client.completions.last_kwargs[:messages].find { |m| m[:role] == "system" }[:content]
    end

    it "threads the candidate block into the system message" do
      adapter.tend(text: "x", facet: "metadata", state: {}, neighbors: [],
                   contract: contract, candidates: candidates)
      expect(system_content).to match(/CANDIDATE VOCABULARY/i)
      expect(system_content).to include("funder")
    end

    it "is byte-identical (no candidate block) when candidates is nil" do
      adapter.tend(text: "x", facet: "metadata", state: {}, neighbors: [], contract: contract, candidates: nil)
      with_nil = system_content
      adapter.tend(text: "x", facet: "metadata", state: {}, neighbors: [], contract: contract)
      expect(with_nil).to eq(system_content)
      expect(with_nil).not_to match(/CANDIDATE VOCABULARY/i)
    end
  end

  describe "#tend with NO contract is byte-identical to v0.2" do
    it "sends RESPONSE_SCHEMA verbatim and the original system text" do
      adapter.tend(text: "x", facet: "summary", state: {}, neighbors: [])
      params = fake_client.completions.last_kwargs

      expect(params[:tools].first[:function][:parameters])
        .to eq(Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA)

      system = params[:messages].find { |m| m[:role] == "system" }[:content]
      expect(system).not_to match(/CONTROLLED VOCABULARY/i)
    end
  end

  # v0.47+: Bedrock-sonnet intermittently returns the `claims` array as a
  # stringified JSON value instead of a native array. When the string is also
  # malformed (model single-escapes embedded quotes), the engine must surface
  # the error loudly (ResponseFormatError) rather than silently dropping all
  # claims and opening a phantom lacuna (rule 3: no silent failures).
  describe "stringified claims recovery (Bedrock-sonnet double-encoding)" do
    def adapter_with_claims_arg(claims_arg)
      client = FakeOpenAIClient.new(
        arguments_json: JSON.generate("claims" => claims_arg, "confidence" => 0.75),
        usage:          usage_payload
      )
      described_class.new(tier: "cheap", base_url: "https://llm.example.com/v1",
                          api_key: "sk-test", client: client)
    end

    context "when claims is a stringified but valid JSON array" do
      let(:stringified_claims) do
        JSON.generate([
          { "key" => "summary", "value" => "A valid summary.", "confidence" => 0.9, "op" => "ADD" },
          { "key" => "topic",   "value" => "Engineering",      "confidence" => 0.8, "op" => "ADD" }
        ])
      end

      it "recovers the claims instead of silently dropping them" do
        result = adapter_with_claims_arg(stringified_claims).tend(
          text: "x", facet: "summary", state: {}, neighbors: []
        )
        expect(result.parsed["claims"].length).to eq(2)
        expect(result.parsed["claims"].first["key"]).to eq("summary")
        expect(result.parsed["claims"].last["key"]).to eq("topic")
      end

      it "normalizes recovered claims to the expected key/value/confidence/op shape" do
        result = adapter_with_claims_arg(stringified_claims).tend(
          text: "x", facet: "summary", state: {}, neighbors: []
        )
        first = result.parsed["claims"].first
        expect(first["key"]).to eq("summary")
        expect(first["value"]).to eq("A valid summary.")
        expect(first["op"]).to eq("ADD")
      end
    end

    context "when claims is a non-empty stringified array with malformed JSON (single-escaped quotes)" do
      # Simulates the real failure: model returns claims as a JSON string but
      # does not double-escape inner quotes, producing unparseable JSON.
      let(:malformed_claims) do
        # Unescaped quotes around "enliteracy" make this invalid JSON when parsed
        '[{"key": "summary", "value": "The concept of "enliteracy" is central.", ' \
        '"confidence": 0.9, "op": "ADD"}]'
      end

      it "raises ResponseFormatError instead of silently producing empty claims" do
        expect {
          adapter_with_claims_arg(malformed_claims).tend(
            text: "x", facet: "summary", state: {}, neighbors: []
          )
        }.to raise_error(Enliterator::Adapters::LLM::ResponseFormatError,
                         /claims string.*could not be parsed/i)
      end

      it "includes a snippet of the offending payload in the error message" do
        expect {
          adapter_with_claims_arg(malformed_claims).tend(
            text: "x", facet: "summary", state: {}, neighbors: []
          )
        }.to raise_error(Enliterator::Adapters::LLM::ResponseFormatError, /enliteracy/)
      end
    end

    context "when claims is a native array (regression guard — unchanged behavior)" do
      it "normalizes them exactly as before" do
        result = adapter.tend(text: "x", facet: "summary", state: {}, neighbors: [])
        expect(result.parsed["claims"].length).to eq(2)
        expect(result.parsed["claims"].first["key"]).to eq("summary")
        expect(result.parsed["claims"].last["key"]).to eq("authored_by")
      end
    end

    context "when claims is genuinely empty (regression guard — must NOT raise)" do
      let(:fake_client) do
        FakeOpenAIClient.new(
          arguments_json: JSON.generate("claims" => [], "confidence" => 0.5),
          usage:          usage_payload
        )
      end

      it "returns empty claims and does not raise" do
        expect {
          result = adapter.tend(text: "x", facet: "summary", state: {}, neighbors: [])
          expect(result.parsed["claims"]).to eq([])
        }.not_to raise_error
      end
    end

    context "when claims key is absent from the response (regression guard — must NOT raise)" do
      let(:fake_client) do
        FakeOpenAIClient.new(
          arguments_json: JSON.generate("confidence" => 0.5),
          usage:          usage_payload
        )
      end

      it "returns empty claims and does not raise" do
        expect {
          result = adapter.tend(text: "x", facet: "summary", state: {}, neighbors: [])
          expect(result.parsed["claims"]).to eq([])
        }.not_to raise_error
      end
    end

    # Pins the valid-empty-JSON boundary: claims as the STRING "[]" is a
    # legitimate stringified empty array — JSON.parse recovers an Array, so the
    # raise guard must NOT fire. A future change to that guard cannot start
    # raising on legitimate empties without breaking this.
    context "when claims is the string \"[]\" (stringified empty array — must NOT raise)" do
      let(:fake_client) do
        FakeOpenAIClient.new(
          arguments_json: JSON.generate("claims" => "[]", "confidence" => 0.5),
          usage:          usage_payload
        )
      end

      it "returns empty claims and does not raise" do
        expect {
          result = adapter.tend(text: "x", facet: "summary", state: {}, neighbors: [])
          expect(result.parsed["claims"]).to eq([])
        }.not_to raise_error
      end
    end
  end
end
