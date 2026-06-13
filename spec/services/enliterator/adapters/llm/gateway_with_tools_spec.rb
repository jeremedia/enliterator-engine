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

  # A fake client whose streaming endpoint replays a canned list of chunks (plain
  # Hashes, mirroring the gem's struct shape). chat.completions.stream_raw(**) returns
  # the Enumerable; the create path is unused on the stream branch.
  class FakeStreamClient
    attr_reader :stream_calls
    def initialize(*chunks) = (@chunks = chunks; @stream_calls = [])
    def chat = self
    def completions = self
    def stream_raw(**params) = (@stream_calls << params; @chunks)
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

  # v0.33 — streamed tool-call assembly. The stream branch now BOTH streams content
  # deltas AND reassembles fragmented tool calls from choice.delta.tool_calls.
  describe "stream: true with a block (v0.33)" do
    def content_chunk(text)
      { "choices" => [ { "delta" => { "content" => text } } ] }
    end

    def tool_chunk(index:, id: nil, name: nil, arguments: nil)
      fn = {}
      fn["name"] = name unless name.nil?
      fn["arguments"] = arguments unless arguments.nil?
      entry = { "index" => index }
      entry["id"] = id unless id.nil?
      entry["function"] = fn
      { "choices" => [ { "delta" => { "tool_calls" => [ entry ] } } ] }
    end

    it "streams content fragments to the block; text-only ToolTurn, no tool calls" do
      client = FakeStreamClient.new(content_chunk("Hel"), content_chunk("lo "), content_chunk("world"))
      gw = described_class.new(tier: "cheap", base_url: "x", api_key: "k", client: client)

      got = []
      out = gw.converse_with_tools(messages: [ { role: "user", content: "hi" } ],
                                   tools: [ tool_def("search") ], stream: true) { |d| got << d }

      expect(got).to eq(%w[Hel lo\  world])
      expect(out.text).to eq("Hello world")
      expect(out.tool_calls).to eq([])
      expect(out.assistant_message).to be_nil
      expect(out.tokens).to eq({})
    end

    it "assembles a fragmented tool call (id/name on first fragment, arguments across chunks)" do
      client = FakeStreamClient.new(
        tool_chunk(index: 0, id: "call_1", name: "search", arguments: '{"q":'),
        tool_chunk(index: 0, arguments: '"x"'),
        tool_chunk(index: 0, arguments: "}")
      )
      gw = described_class.new(tier: "cheap", base_url: "x", api_key: "k", client: client)

      called = false
      out = gw.converse_with_tools(messages: [ { role: "user", content: "hi" } ],
                                   tools: [ tool_def("search") ], stream: true) { |_d| called = true }

      expect(called).to be(false) # no content deltas → block never fired
      expect(out.text).to eq("")
      expect(out.tool_calls).to eq([ { id: "call_1", name: "search", arguments: { "q" => "x" } } ])
      # assistant_message carries the raw (un-parsed) arguments string, same shape as non-stream.
      tc = out.assistant_message["tool_calls"].first
      expect(out.assistant_message["role"]).to eq("assistant")
      expect(out.assistant_message["content"]).to be_nil
      expect(tc["id"]).to eq("call_1")
      expect(tc["type"]).to eq("function")
      expect(tc["function"]).to eq({ "name" => "search", "arguments" => '{"q":"x"}' })
    end

    it "assembles TWO tool calls (index 0 and 1) in order" do
      client = FakeStreamClient.new(
        tool_chunk(index: 0, id: "call_a", name: "search", arguments: '{"q":"x"}'),
        tool_chunk(index: 1, id: "call_b", name: "provenance", arguments: '{"claim_id":'),
        tool_chunk(index: 1, arguments: "7}")
      )
      gw = described_class.new(tier: "cheap", base_url: "x", api_key: "k", client: client)

      out = gw.converse_with_tools(messages: [ { role: "user", content: "hi" } ],
                                   tools: [ tool_def("search"), tool_def("provenance") ], stream: true) { |_d| }

      expect(out.tool_calls).to eq([
        { id: "call_a", name: "search", arguments: { "q" => "x" } },
        { id: "call_b", name: "provenance", arguments: { "claim_id" => 7 } }
      ])
      expect(out.assistant_message["tool_calls"].map { |tc| tc["id"] }).to eq(%w[call_a call_b])
    end

    it "handles a content preamble followed by tool-call chunks (text AND tool_calls)" do
      client = FakeStreamClient.new(
        content_chunk("Let me look that up. "),
        tool_chunk(index: 0, id: "call_1", name: "search", arguments: '{"q":"x"}')
      )
      gw = described_class.new(tier: "cheap", base_url: "x", api_key: "k", client: client)

      got = []
      out = gw.converse_with_tools(messages: [ { role: "user", content: "hi" } ],
                                   tools: [ tool_def("search") ], stream: true) { |d| got << d }

      expect(got).to eq([ "Let me look that up. " ])
      expect(out.text).to eq("Let me look that up. ")
      expect(out.tool_calls).to eq([ { id: "call_1", name: "search", arguments: { "q" => "x" } } ])
      expect(out.assistant_message["tool_calls"].size).to eq(1)
    end
  end
end
