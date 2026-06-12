# spec/services/enliterator/adapters/llm/gateway_with_tools_spec.rb
# frozen_string_literal: true
require "rails_helper"

# v0.28 — converse_with_tools: optional-multi-tool. Returns a struct describing
# EITHER a final answer (text) OR a set of tool calls to execute. A fake client
# returns canned chat-completion hashes; no gem, no network.
RSpec.describe Enliterator::Adapters::LLM::Gateway do
  # A fake openai client: records the params it was called with, returns the next
  # queued response. Mirrors the gem's nested shape client.chat.completions.create.
  class FakeToolClient
    attr_reader :calls
    def initialize(*responses) = (@responses = responses; @calls = [])
    def chat = self
    def completions = self
    def create(**params)
      @calls << params
      @responses.shift
    end
  end

  def tool_def(name)
    { "type" => "function", "function" => { "name" => name, "description" => "x",
                                            "parameters" => { "type" => "object", "properties" => {} } } }
  end

  it "returns the assistant's tool calls (all of them, with ids) when the model calls tools" do
    response = { "choices" => [ { "message" => { "tool_calls" => [
      { "id" => "call_1", "function" => { "name" => "search", "arguments" => '{"q":"x"}' } },
      { "id" => "call_2", "function" => { "name" => "record_entry", "arguments" => '{"type":"DocMetum","id":"7"}' } }
    ] } } ], "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 } }
    gw = described_class.new(tier: "cheap", base_url: "x", api_key: "k", client: FakeToolClient.new(response))

    out = gw.converse_with_tools(messages: [ { role: "user", content: "hi" } ], tools: [ tool_def("search"), tool_def("record_entry") ])

    expect(out.tool_calls.map { |c| [ c[:id], c[:name], c[:arguments] ] }).to eq(
      [ [ "call_1", "search", { "q" => "x" } ], [ "call_2", "record_entry", { "type" => "DocMetum", "id" => "7" } ] ]
    )
    expect(out.text).to be_nil
    expect(out.tokens["total"]).to eq(15)
    # The assistant turn (with its raw tool_calls) is returned for the loop to append before the tool results.
    expect(out.assistant_message["tool_calls"].size).to eq(2)
  end

  it "returns a final answer (text, no tool calls) when the model stops calling tools, streaming deltas to the block" do
    client   = FakeToolClient.new # stream path uses stream_raw; stub it below
    def client.stream_raw(**_); [ { "choices" => [ { "delta" => { "content" => "Hello " } } ] },
                                  { "choices" => [ { "delta" => { "content" => "world" } } ] } ]; end
    gw = described_class.new(tier: "cheap", base_url: "x", api_key: "k", client: client)

    got = +""
    out = gw.converse_with_tools(messages: [ { role: "user", content: "hi" } ], tools: [ tool_def("search") ], stream: true) { |d| got << d }

    expect(got).to eq("Hello world")
    expect(out.text).to eq("Hello world")
    expect(out.tool_calls).to eq([])
  end

  it "passes tool_choice auto and the tools array through to the client" do
    response = { "choices" => [ { "message" => { "content" => "done" } } ] }
    client = FakeToolClient.new(response)
    gw = described_class.new(tier: "cheap", base_url: "x", api_key: "k", client: client)
    gw.converse_with_tools(messages: [ { role: "user", content: "hi" } ], tools: [ tool_def("search") ])
    expect(client.calls.first[:tool_choice]).to eq("auto")
    expect(client.calls.first[:tools].first.dig("function", "name")).to eq("search")
  end
end
