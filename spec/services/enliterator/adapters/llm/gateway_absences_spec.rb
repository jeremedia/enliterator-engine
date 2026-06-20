# frozen_string_literal: true

require "rails_helper"

# v0.46.1 — the Gateway (HSDL's live path) must (1) thread `required:` into the tool
# parameter schema so the absences property appears when the flag is on, and (2) pass
# a model-emitted `absences` array through extract_parsed, normalized to the string-keyed
# {term, diagnosis, note} shape the Visitor's absences_index reads. Flag off → no
# absences in the schema and (since the model never emits it) none in parsed: byte-identical.
RSpec.describe "Enliterator::Adapters::LLM::Gateway absences channel (v0.46.1)" do
  # Minimal OpenAI-compatible fake: records create kwargs, returns a forced tool call
  # whose arguments JSON the adapter must parse. Self-contained (no cross-spec classes).
  class AbsFakeCompletions
    attr_reader :last_kwargs
    def initialize(arguments_json:) = @arguments_json = arguments_json
    def create(**kwargs)
      @last_kwargs = kwargs
      { "choices" => [ { "message" => { "role" => "assistant", "tool_calls" => [
        { "type" => "function",
          "function" => { "name" => Enliterator::Adapters::LLM::Base::TOOL_NAME,
                          "arguments" => @arguments_json } } ] } } ],
        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12 } }
    end
  end

  class AbsFakeClient
    attr_reader :completions
    def initialize(arguments_json:) = @completions = AbsFakeCompletions.new(arguments_json: arguments_json)
    def chat = self
  end

  let(:contract) { { "authored_by" => "The author(s).", "advisor" => "The advisor(s)." } }
  let(:required) { [ "authored_by" ] }

  def client_for(arguments_json) = AbsFakeClient.new(arguments_json: arguments_json)

  def adapter_for(client)
    Enliterator::Adapters::LLM::Gateway.new(
      tier: "cheap", base_url: "https://llm.example.com/v1", api_key: "sk-test", client: client
    )
  end

  def tend!(adapter)
    adapter.tend(text: "doc", facet: "authorship", state: {}, neighbors: [],
                 contract: contract, required: required)
  end

  describe "parse — extract_parsed passes absences through" do
    let(:args) do
      JSON.generate(
        "claims" => [ { "key" => "advisor", "value" => "Dr. A", "confidence" => 0.8, "op" => "ADD" } ],
        "confidence" => 0.6,
        "absences" => [ { "term" => "authored_by", "diagnosis" => "silent", "note" => "no byline on the title page" } ]
      )
    end

    it "surfaces a normalized string-keyed absences array" do
      result = tend!(adapter_for(client_for(args)))
      expect(result.parsed["absences"]).to eq(
        [ { "term" => "authored_by", "diagnosis" => "silent", "note" => "no byline on the title page" } ]
      )
    end

    it "omits the absences key entirely when the model emits none" do
      noabs = JSON.generate("claims" => [], "confidence" => 0.5)
      expect(tend!(adapter_for(client_for(noabs))).parsed).not_to have_key("absences")
    end
  end

  describe "schema — the tool parameters carry absences only when the flag is on" do
    let(:args) { JSON.generate("claims" => [], "confidence" => 0.5) }

    it "includes the absences property when record_lacunae is on" do
      Enliterator.configure { |c| c.record_lacunae = true }
      client = client_for(args)
      tend!(adapter_for(client))
      params = client.completions.last_kwargs.dig(:tools, 0, :function, :parameters)
      expect(params["properties"]).to have_key("absences")
    end

    it "omits the absences property when the flag is off (byte-identical schema)" do
      client = client_for(args)
      tend!(adapter_for(client))
      params = client.completions.last_kwargs.dig(:tools, 0, :function, :parameters)
      expect(params["properties"]).not_to have_key("absences")
    end
  end
end
