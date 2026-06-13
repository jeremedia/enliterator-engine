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

  # The OFF-view byte-identity guarantee, codified. The implementers proved by
  # literal diff that with federation OFF the server-rendered chat page emits
  # NONE of the agentic surface: no trace/widget/citation DOM, and none of the
  # federation-only JS. The whole agentic block lives behind a single ERB gate
  # (`<% if Enliterator.configuration.chat_federation %>`) in the view, so OFF
  # withholds the MARKUP entirely. This freezes that contract so a future refactor
  # that leaks federated markup or JS onto the OFF page fails loudly here.
  #
  # CRITICAL DISTINCTION — the `enl-*` CSS is intentionally NOT withheld. The
  # namespaced widget/trace/citation CSS lives in the shared layout's <style>
  # block and renders on EVERY page (it is `enl-*`-scoped, so it selects nothing
  # when no element carries those classes — inert by namespace, present by
  # design; see the layout's own note). So "the agentic surface is absent" means
  # absent from the DOM and JS, not absent from the inert CSS selector text. We
  # therefore assert against the page body with the layout <style> block stripped:
  # what remains is the markup + the page script, which is exactly the surface the
  # federation gate governs.
  describe "GET /enliterator/chat with federation OFF (the agentic surface is absent)" do
    # The agentic DOM classes (trace timeline, tool-result rows, inline citation
    # chips, sources rail, handoff divider) — every one is emitted as MARKUP only
    # inside the federation gate.
    AGENTIC_DOM = %w[enl-trace enl-result enl-cite enl-sources enl-handoff].freeze
    # The federation-only JS: both the entrypoint shims and the turn-model
    # helpers. None is defined or called on the OFF path.
    FEDERATED_JS = %w[
      handleFrameFederated submitQuestionFederated finishTurnFederated
      annotateCites makeCiteChip buildCitePop wrapFirstMatch
    ].freeze

    before { Enliterator.configuration.chat_federation = nil }

    # The page minus the shared layout's inert <style> block (the CSS that is
    # present-by-design on every page). What's left is the DOM + the page script.
    def body_without_layout_css
      response.body.gsub(%r{<style\b[^>]*>.*?</style>}m, "")
    end

    it "renders the chat page but emits none of the agentic DOM or federated JS" do
      get "/enliterator/chat"
      expect(response).to have_http_status(:ok)
      # POSITIVE: it IS the chat page (the single-shot surface still renders).
      expect(response.body).to include("Chat with the enliteration")
      # Sanity: the strip removed the inert CSS (those selectors WERE present in
      # the layout's <style>), so a leak we catch below is a real DOM/JS leak.
      expect(response.body).to include(".enl-trace")               # inert CSS, in <style>
      expect(body_without_layout_css).not_to include(".enl-trace") # ...and only there

      page = body_without_layout_css
      # NEGATIVE: not one agentic class in the DOM, not one federated function name.
      AGENTIC_DOM.each do |cls|
        expect(page).not_to include(cls), "OFF view leaked agentic DOM class #{cls}"
      end
      FEDERATED_JS.each do |fn|
        expect(page).not_to include(fn), "OFF view leaked federated JS #{fn}"
      end
      # The federation-only scope-banner id is also withheld (it is added as an
      # element attribute only inside the gate — never a CSS selector).
      expect(response.body).not_to include("enl-scope-banner")
    end
  end
end
