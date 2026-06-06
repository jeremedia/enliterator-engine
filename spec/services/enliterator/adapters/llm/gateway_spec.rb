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
        stream:    "summary",
        state:     { claims: [], recent_visits: [], facets: {} },
        neighbors: [],
        tags:      %w[enliterator host:dummy stream:summary tier:cheap esc:0]
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
      expect(tags).to eq(%w[enliterator host:dummy stream:summary tier:cheap esc:0])
      expect(tags).to be_an(Array)
    end

    it "omits request_options entirely when no tags are passed (v0.1-shaped call)" do
      adapter.tend(
        text:      "x",
        stream:    "summary",
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
      result = adapter.tend(text: "x", stream: "summary", state: {}, neighbors: [])
      expect(result.parsed["escalate"]).to be(true)
    end
  end

  # v0.3 §2 — when a contract is passed, the request's tool schema constrains the
  # claim `key` to an enum over the allowed keys AND advertises an optional
  # top-level `suggestions` array, while the system message gains a controlled-
  # vocabulary block. When NO contract is passed the request stays byte-identical
  # to v0.2 (parameters == RESPONSE_SCHEMA, no suggestions, original system text).
  describe "#tend with a stream contract" do
    let(:contract) do
      { author: "Who authored the work.", date: "When the work was created." }
    end

    def request_params!
      adapter.tend(
        text:      "x",
        stream:    "metadata",
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

  describe "#tend with NO contract is byte-identical to v0.2" do
    it "sends RESPONSE_SCHEMA verbatim and the original system text" do
      adapter.tend(text: "x", stream: "summary", state: {}, neighbors: [])
      params = fake_client.completions.last_kwargs

      expect(params[:tools].first[:function][:parameters])
        .to eq(Enliterator::Adapters::LLM::Base::RESPONSE_SCHEMA)

      system = params[:messages].find { |m| m[:role] == "system" }[:content]
      expect(system).not_to match(/CONTROLLED VOCABULARY/i)
    end
  end
end
