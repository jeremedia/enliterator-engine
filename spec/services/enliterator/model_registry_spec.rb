# frozen_string_literal: true

require "rails_helper"

# v0.68.1 — the deployment map.
#
# v0.68 shipped reading the resolved model from the chat response body. The live
# gateway echoes the requested alias there, so the fallback fired on every call
# and provenance kept recording the alias. This pins the corrected source and,
# more importantly, pins that the lookup NEVER touches the wire unless a host has
# explicitly opted in — an unopted host must behave exactly as v0.68.
RSpec.describe Enliterator::ModelRegistry do
  let(:base_url) { "https://llm.example/v1" }

  around do |ex|
    prior = Enliterator.configuration.resolve_model_backends
    described_class.reset!
    ex.run
    Enliterator.configuration.resolve_model_backends = prior
    described_class.reset!
  end

  # The live shape, captured from GET https://llm.domt.app/v1/model/info.
  def stub_info!
    allow(described_class).to receive(:fetch).and_return(
      "enliterator-draft"   => { model: "bedrock_mantle/openai.gpt-5.4",       deployment: "cbeb111e" },
      "enliterator-quality" => { model: "bedrock_mantle/openai.gpt-5.6-terra", deployment: "374a0bcf" }
    )
  end

  context "when the host has NOT opted in (the default)" do
    before { Enliterator.configuration.resolve_model_backends = nil }

    it "returns nil without consulting the gateway at all" do
      expect(described_class).not_to receive(:fetch)
      expect(described_class.backend_for("enliterator-draft", base_url: base_url, api_key: "k")).to be_nil
    end

    it "returns an empty map without consulting the gateway" do
      expect(described_class).not_to receive(:fetch)
      expect(described_class.map(base_url: base_url, api_key: "k")).to eq({})
    end
  end

  context "when the host has opted in" do
    before do
      Enliterator.configuration.resolve_model_backends = true
      stub_info!
    end

    it "resolves an alias to the underlying model" do
      expect(described_class.backend_for("enliterator-draft", base_url: base_url, api_key: "k"))
        .to eq("bedrock_mantle/openai.gpt-5.4")
    end

    it "exposes the deployment id — the value that changes on a repoint" do
      expect(described_class.deployment_for("enliterator-quality", base_url: base_url, api_key: "k"))
        .to eq("374a0bcf")
    end

    it "returns nil for an alias the gateway does not publish" do
      expect(described_class.backend_for("no-such-tier", base_url: base_url, api_key: "k")).to be_nil
    end

    it "never raises when the gateway is unreachable — a metadata lookup must not break a tend" do
      allow(described_class).to receive(:fetch).and_raise(Errno::ECONNREFUSED)
      expect { described_class.map(base_url: base_url, api_key: "k") }.not_to raise_error
      expect(described_class.map(base_url: base_url, api_key: "k")).to eq({})
    end
  end

  describe "the Gateway adapter's use of it" do
    # Echoes the alias back, exactly as the live LiteLLM does.
    class EchoingCompletions
      def create(**_kwargs)
        { "model" => "enliterator-draft",
          "choices" => [ { "message" => { "role" => "assistant", "tool_calls" => [
            { "type" => "function", "function" => {
              "name" => Enliterator::Adapters::LLM::Base::TOOL_NAME,
              "arguments" => { claims: [], confidence: 0.9 }.to_json } }
          ] } } ],
          "usage" => { "total_tokens" => 5 } }
      end
    end
    class EchoingClient
      def chat = self
      def completions = @completions ||= EchoingCompletions.new
    end

    def tend!
      Enliterator::Adapters::LLM::Gateway.new(
        tier: "enliterator-draft", base_url: base_url, api_key: "k", client: EchoingClient.new
      ).tend(text: "t", facet: "summary", state: {}, neighbors: [])
    end

    it "records the ALIAS when unopted — the v0.68 behavior, unchanged" do
      Enliterator.configuration.resolve_model_backends = nil
      expect(tend!.model).to eq("enliterator-draft")
    end

    it "records the RESOLVED BACKEND when opted in, despite the echoed alias" do
      Enliterator.configuration.resolve_model_backends = true
      stub_info!
      expect(tend!.model).to eq("bedrock_mantle/openai.gpt-5.4")
    end
  end
end
