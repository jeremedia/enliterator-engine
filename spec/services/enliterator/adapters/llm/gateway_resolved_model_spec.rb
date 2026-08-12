# frozen_string_literal: true

require "rails_helper"

# v0.68 — RESOLVED-MODEL PROVENANCE.
#
# The tier alias ("enliterator-quality") is what we ASK the gateway for; it is not
# what answered. LiteLLM resolves an alias to a deployment and reports the resolved
# model back in the response body. Before v0.68 the engine recorded the alias in
# BOTH Visit.tier and Visit.model, and in Audit.auditor — so when the gateway
# repointed `enliterator-deep` from claude-opus-4-8 to a GPT backend (2026-08-12),
# every row on both sides of the swap read "enliterator-deep" and the change was
# invisible in the provenance record. A collection that claims PROV-style
# provenance cannot lose the identity of the model that made the claim.
#
# Contract: `tier` keeps the REQUESTED alias, `model` carries the RESOLVED backend,
# and when the response reports no model we fall back to the alias (byte-identical
# to pre-v0.68 behavior — never invent provenance we don't have).
RSpec.describe "v0.68 resolved-model provenance" do
  # Chat-completion-shaped fake whose response optionally carries a top-level
  # "model" — exactly where LiteLLM reports the resolved deployment.
  class ResolvedModelCompletions
    attr_reader :last_kwargs

    def initialize(resolved:)
      @resolved = resolved
    end

    def create(**kwargs)
      @last_kwargs = kwargs
      body = {
        "choices" => [
          { "message" => { "role" => "assistant", "tool_calls" => [
            { "type" => "function", "function" => {
              "name" => Enliterator::Adapters::LLM::Base::TOOL_NAME,
              "arguments" => { claims: [], confidence: 0.9 }.to_json
            } }
          ] } }
        ],
        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12 }
      }
      body["model"] = @resolved unless @resolved.nil?
      body
    end
  end

  class ResolvedModelClient
    attr_reader :completions
    def initialize(resolved:) = @completions = ResolvedModelCompletions.new(resolved: resolved)
    def chat = self
  end

  # Gateway#client is private, so keep our own handle to the injected fake.
  attr_reader :fake

  def adapter_for(resolved)
    @fake = ResolvedModelClient.new(resolved: resolved)
    Enliterator::Adapters::LLM::Gateway.new(
      tier: "enliterator-deep", base_url: "https://llm.example/v1",
      api_key: "k", client: @fake
    )
  end

  def sent_kwargs = fake.chat.completions.last_kwargs

  def tend_once(adapter)
    adapter.tend(text: "t", facet: "summary", state: {}, neighbors: [])
  end

  describe "#tend" do
    it "reports the RESOLVED backend, not the alias we asked for" do
      result = tend_once(adapter_for("bedrock_mantle/openai.gpt-5.6-sol"))
      expect(result.model).to eq("bedrock_mantle/openai.gpt-5.6-sol")
    end

    it "falls back to the tier alias when the response reports no model" do
      result = tend_once(adapter_for(nil))
      expect(result.model).to eq("enliterator-deep")
    end

    it "falls back to the alias when the reported model is blank" do
      expect(tend_once(adapter_for("   ")).model).to eq("enliterator-deep")
    end

    it "still sends the ALIAS as the request's model id (routing is unchanged)" do
      tend_once(adapter_for("bedrock_mantle/openai.gpt-5.6-sol"))
      expect(sent_kwargs[:model]).to eq("enliterator-deep")
    end

    it "leaves #model_id as the alias — routing identity, not answering identity" do
      expect(adapter_for("x").model_id).to eq("enliterator-deep")
    end
  end

  describe "#decide with a meta out-param" do
    # The examiner path. State CANNOT live on the adapter: Enliterator.llm memoizes
    # one Gateway per tier and shares it across threads (heartbeat thread + request
    # threads), so a @last_resolved_model would cross-stamp under concurrency. The
    # caller owns the hash; the adapter only fills it.
    it "populates meta[:model] with the resolved backend" do
      meta = {}
      adapter_for("bedrock_mantle/openai.gpt-5.6-terra")
        .decide(messages: [], schema: {}, tool_name: "t", meta: meta)
      expect(meta[:model]).to eq("bedrock_mantle/openai.gpt-5.6-terra")
    end

    it "falls back to the alias in meta when the response reports no model" do
      meta = {}
      adapter_for(nil).decide(messages: [], schema: {}, tool_name: "t", meta: meta)
      expect(meta[:model]).to eq("enliterator-deep")
    end

    it "works unchanged when no meta is passed (pre-v0.68 callers)" do
      expect { adapter_for("x").decide(messages: [], schema: {}, tool_name: "t") }
        .not_to raise_error
    end
  end

  # v0.68 companion guard. Mantle-routed GPT rejects max_output_tokens < 16, and
  # surfaces it as an HTTP 500 APIConnectionError — indistinguishable from a
  # transport fault, which invites blind retry into the same wall. Claude accepted
  # these values, so a host carrying a small cap from the Anthropic era would break
  # opaquely. Clamp loudly instead (rule 3: no silent failures).
  describe "gateway_max_tokens floor" do
    around do |ex|
      prior = Enliterator.configuration.gateway_max_tokens
      ex.run
      Enliterator.configuration.gateway_max_tokens = prior
    end

    def sent_params(cap)
      Enliterator.configuration.gateway_max_tokens = cap
      tend_once(adapter_for("m"))
      sent_kwargs
    end

    it "sends NO max_tokens when unset (the default request is unchanged)" do
      expect(sent_params(nil)).not_to have_key(:max_tokens)
    end

    it "passes a cap at or above the floor through untouched" do
      expect(sent_params(4096)[:max_tokens]).to eq(4096)
    end

    it "clamps a sub-floor cap up to the floor rather than sending a 500-maker" do
      expect(sent_params(8)[:max_tokens]).to eq(16)
    end

    it "says so in the log when it clamps" do
      logger = instance_double(Logger, warn: nil, info: nil, debug: nil, error: nil)
      allow(Enliterator).to receive(:logger).and_return(logger)
      sent_params(1)
      expect(logger).to have_received(:warn).with(/gateway_max_tokens/i)
    end
  end
end
