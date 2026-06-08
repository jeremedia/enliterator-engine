# frozen_string_literal: true

require "rails_helper"

# v0.6 free-form conversational completion. Gateway#converse uses NO forced tool:
# streaming via chat.completions.stream_raw (yields delta.content chunks), non-
# streaming via chat.completions.create (message.content). Null#converse returns a
# canned answer and streams it token-by-token. No network, no openai gem touched.
RSpec.describe "LLM #converse (v0.6)" do
  describe Enliterator::Adapters::LLM::Null do
    subject(:adapter) { described_class.new }

    it "returns the canned answer (non-streaming)" do
      expect(adapter.converse(messages: [])).to eq(described_class::CANNED_REPLY)
    end

    it "streams the canned answer in tokens that reassemble to the whole" do
      chunks = []
      full = adapter.converse(messages: [], stream: true) { |t| chunks << t }
      expect(chunks.join).to eq(described_class::CANNED_REPLY)
      expect(full).to eq(described_class::CANNED_REPLY)
      expect(chunks.size).to be > 1
    end

    it "does NOT raise even when allow_null_llm is false (write-free path)" do
      Enliterator.configuration.allow_null_llm = false
      expect { adapter.converse(messages: []) }.not_to raise_error
    end
  end

  describe Enliterator::Adapters::LLM::Gateway do
    # Two-level fake: client.chat.completions.{create, stream_raw}. Returns
    # OpenAI-chat-shaped Hashes (string keys), exactly what the adapter must tolerate.
    class ConverseStubCompletions
      attr_reader :last_create_kwargs, :last_stream_kwargs

      def initialize(content:, chunks:)
        @content = content
        @chunks  = chunks
      end

      def create(**kwargs)
        @last_create_kwargs = kwargs
        { "choices" => [ { "message" => { "role" => "assistant", "content" => @content } } ] }
      end

      def stream_raw(**kwargs)
        @last_stream_kwargs = kwargs
        # A trailing role-only chunk (no content) proves nil deltas are skipped.
        @chunks.map { |c| { "choices" => [ { "delta" => { "content" => c } } ] } } +
          [ { "choices" => [ { "delta" => { "role" => "assistant" } } ] } ]
      end
    end

    class ConverseStubClient
      attr_reader :completions
      def initialize(content:, chunks:)
        @completions = ConverseStubCompletions.new(content: content, chunks: chunks)
      end
      def chat = self
    end

    let(:answer) { "The collection foregrounds disaster response." }
    let(:client) { ConverseStubClient.new(content: answer, chunks: [ "The ", "collection ", "foregrounds ", "disaster ", "response." ]) }
    let(:adapter) { described_class.new(tier: "quality", base_url: "http://x/v1", api_key: "k", client: client) }

    it "non-streaming returns the assistant message content, with NO forced tool" do
      out = adapter.converse(messages: [ { role: "user", content: "what's here?" } ])
      expect(out).to eq(answer)
      expect(client.completions.last_create_kwargs[:model]).to eq("quality")
      expect(client.completions.last_create_kwargs).not_to have_key(:tools)
      expect(client.completions.last_create_kwargs).not_to have_key(:tool_choice)
    end

    it "streaming yields delta content in order (skipping the content-less chunk) and returns the full string" do
      got = []
      full = adapter.converse(messages: [ { role: "user", content: "hi" } ], stream: true) { |d| got << d }
      expect(got).to eq([ "The ", "collection ", "foregrounds ", "disaster ", "response." ])
      expect(full).to eq(answer)
    end

    it "routes spend tags through extra_body so the array reaches LiteLLM unmangled" do
      adapter.converse(messages: [], tags: %w[enliterator conversation], stream: true) { |_| }
      tags = client.completions.last_stream_kwargs.dig(:request_options, :extra_body, :metadata, :tags)
      expect(tags).to eq(%w[enliterator conversation])
    end
  end
end
