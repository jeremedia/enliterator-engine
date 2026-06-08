# frozen_string_literal: true

require "rails_helper"

# v0.6 conversation UI. The SSE stream is deliberately DB-independent: a stub LLM
# yields canned chunks, so the ActionController::Live thread (separate DB
# connection, can't see uncommitted fixtures) never needs the test's seeded rows.
RSpec.describe "Enliterator conversation", type: :request do
  # Configured as configuration.llm_adapter so Enliterator.llm(tier:) returns it
  # (gateway unconfigured in tests) — no mocking of Enliterator.llm needed.
  class SseStubLLM
    def model_id = "stub"
    def converse(messages:, tags: [], stream: false, &block)
      [ "Hello ", "from ", "the ", "collection." ].each { |c| block.call(c) } if stream && block
      "Hello from the collection."
    end
  end

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        stream :summary, tier: "cheap", keys: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
      c.llm_adapter = SseStubLLM.new
    end
  end

  it "GET /enliterator/chat renders the chat page" do
    get "/enliterator/chat"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Chat with the enliteration")
  end

  it "POST /enliterator/chat/stream streams SSE token frames, then provenance + done" do
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response.media_type).to eq("text/event-stream")
    expect(response.body).to include("event: token")
    expect(response.body).to include("Hello ")          # a streamed delta
    expect(response.body).to include("event: provenance")
    expect(response.body).to include("event: done")
  end
end
