# frozen_string_literal: true

require "rails_helper"

# v0.8 general forced-tool structured call. Gateway#decide forces a caller-named
# tool bound to a caller-supplied schema and returns the parsed arguments. Null
# returns an empty result (CI-inert). No network.
RSpec.describe "LLM #decide (v0.8)" do
  describe Enliterator::Adapters::LLM::Null do
    it "returns an empty structured result" do
      expect(described_class.new.decide(messages: [], schema: {}, tool_name: "x")).to eq({})
    end
  end

  describe Enliterator::Adapters::LLM::Gateway do
    class DecideStubCompletions
      attr_reader :last_kwargs
      def initialize(args_json:) = (@args_json = args_json)
      def create(**kwargs)
        @last_kwargs = kwargs
        { "choices" => [ { "message" => { "tool_calls" => [
          { "type" => "function", "function" => { "name" => "recommend_vocabulary", "arguments" => @args_json } }
        ] } } ] }
      end
    end
    class DecideStubClient
      attr_reader :completions
      def initialize(args_json:) = (@completions = DecideStubCompletions.new(args_json: args_json))
      def chat = self
    end

    let(:args_json) do
      JSON.generate("recommendations" => [
        { "proposed_key" => "author", "decision" => "map", "map_to" => "authored_by", "rationale" => "syn", "confidence" => 0.9 }
      ])
    end
    let(:client)  { DecideStubClient.new(args_json: args_json) }
    let(:adapter) { described_class.new(tier: "quality", base_url: "http://x/v1", api_key: "k", client: client) }
    let(:schema)  { { "type" => "object", "properties" => {} } }

    it "forces the named tool with the given schema and parses the arguments" do
      out = adapter.decide(messages: [ { role: "user", content: "go" } ], schema: schema, tool_name: "recommend_vocabulary")
      expect(out["recommendations"].first["proposed_key"]).to eq("author")
      kw = client.completions.last_kwargs
      expect(kw[:tool_choice]).to eq(type: "function", function: { name: "recommend_vocabulary" })
      expect(kw[:tools].first[:function][:parameters]).to eq(schema)
    end

    it "routes spend tags via extra_body" do
      adapter.decide(messages: [], schema: schema, tool_name: "recommend_vocabulary", tags: %w[enliterator considerer])
      expect(client.completions.last_kwargs.dig(:request_options, :extra_body, :metadata, :tags)).to eq(%w[enliterator considerer])
    end
  end
end
