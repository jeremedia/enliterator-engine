# frozen_string_literal: true
require "rails_helper"

RSpec.describe "Conversation federation", type: :request do
  # The OFF example must exercise the REAL single-shot path (Conversation#reply
  # streaming), so it needs the same staffing policy + SSE-stub LLM the existing
  # conversation_spec uses — otherwise an empty config could pass it vacuously.
  class FederationSseStubLLM
    def model_id = "stub"
    def converse(messages:, tags: [], stream: false, &block)
      [ "Hello ", "from ", "the ", "collection." ].each { |c| block.call(c) } if stream && block
      "Hello from the collection."
    end
  end

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
      c.llm_adapter = FederationSseStubLLM.new
    end
  end

  after { Enliterator.configuration.chat_federation = nil; Enliterator::Chat.reset! }

  it "with federation OFF, the stream uses the single-shot path (no widget/handoff events)" do
    Enliterator.configuration.chat_federation = nil
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response).to have_http_status(:ok)
    # POSITIVE: the single-shot path actually ran (token deltas + its provenance + done).
    expect(response.body).to include("event: token")
    expect(response.body).to include("Hello ")          # a streamed delta from the stub
    expect(response.body).to include("event: provenance")
    expect(response.body).to include("event: done")
    # NEGATIVE: none of the loop's new events.
    expect(response.body).not_to include("event: tool_call_result")
    expect(response.body).not_to include("event: handoff")
  end

  it "with federation ON, the stream drives the loop (emits a token then done)" do
    Enliterator.configuration.chat_federation = true
    allow(Enliterator).to receive(:llm).and_return(
      double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
        text: "the answer", tool_calls: [], assistant_message: nil, tokens: {})))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response.body).to include("event: token")
    expect(response.body).to include("the answer")
    expect(response.body).to include("event: done")
  end

  it "degrades gracefully when federation is on but no agent is registered" do
    Enliterator.configuration.chat_federation = true
    Enliterator::Chat.reset!
    expect { post "/enliterator/chat/stream", params: { question: "hi" } }.not_to raise_error
    expect(response).to have_http_status(:ok)
  end
end
