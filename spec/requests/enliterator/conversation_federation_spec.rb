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

  after { Enliterator.configuration.chat_federation = nil; Enliterator.configuration.chat_followups = nil; Enliterator.configuration.chat_register = nil; Enliterator::Chat.reset! }

  # Helper: pull the JSON object that follows an `event: error` line in an SSE body.
  # The controller writes "event: error\n" then "data: <json>\n\n". Returns the parsed
  # Hash, or nil if no error event was emitted.
  def error_event_data(body)
    # Match the data: line immediately following the error event line.
    m = body.match(/event: error\ndata: (?<json>.+)\n/)
    m && JSON.parse(m[:json])
  end

  # v0.30: the controller's outer rescue routes the stream error through ErrorReport,
  # gated by Enliterator.configuration.error_detail?. These pin the three safety
  # invariants: prod (detail off) is BYTE-IDENTICAL to today's {message: "conversation
  # failed"}; detail on carries actionable detail; and NO request param can flip the gate.
  describe "stream error reporting (the outer rescue → ErrorReport)" do
    # error_detail defaults to false in the test env, but we set it per-example and
    # restore it so no example leaks the config to its neighbors.
    around do |example|
      prev = Enliterator.configuration.error_detail
      example.run
      Enliterator.configuration.error_detail = prev
    end

    # Force the SINGLE-SHOT path's collaborator to raise — the recognizable message is
    # timeout-ish so a hint resolves when detail is on (proves the hint plumbing).
    def force_single_shot_raise!
      Enliterator.configuration.chat_federation = nil
      conv = instance_double(Enliterator::Conversation)
      allow(Enliterator::Conversation).to receive(:new).and_return(conv)
      allow(conv).to receive(:reply).and_raise(StandardError.new("upstream request timed out"))
    end

    it "with detail OFF (prod), the error payload is exactly the message floor (byte-identity)" do
      Enliterator.configuration.error_detail = false
      force_single_shot_raise!

      post "/enliterator/chat/stream", params: { question: "hi" }

      expect(response.body).to include("event: error")
      data = error_event_data(response.body)
      # The prod floor: exactly today's payload, nothing more.
      expect(data).to eq("message" => "conversation failed")
      expect(data).not_to have_key("detail")
      expect(data).not_to have_key("where")
      expect(data).not_to have_key("hint")
    end

    it "with detail ON, the error payload carries actionable detail (and a matching hint)" do
      Enliterator.configuration.error_detail = true
      force_single_shot_raise!

      post "/enliterator/chat/stream", params: { question: "hi" }

      expect(response.body).to include("event: error")
      data = error_event_data(response.body)
      # message floor is still the static literal — never e.message.
      expect(data["message"]).to eq("conversation failed")
      # ...but now actionable detail rides along.
      expect(data["detail"]).to include("StandardError")
      expect(data["detail"]).to include("timed out")
      expect(data["where"]).to include("stream")     # humanized {stage: "stream"}
      expect(data["hint"]).to match(/timed out|gateway timed out/i)  # the timeout HINT resolved
    end

    it "NO request param can enable detail — prod stays message-only even with debug/detail params" do
      Enliterator.configuration.error_detail = false   # prod
      force_single_shot_raise!

      # A user-supplied param must NOT route around the gate.
      post "/enliterator/chat/stream", params: { question: "hi", debug: "1", detail: "1" }

      expect(response.body).to include("event: error")
      data = error_event_data(response.body)
      expect(data).to eq("message" => "conversation failed")
      expect(data).not_to have_key("detail")
    end

    it "the FEDERATION path's stream error also routes through the gated report" do
      Enliterator.configuration.error_detail = false   # prod floor
      Enliterator.configuration.chat_federation = true
      # Force the loop construction/run to raise inside the controller's try block so the
      # OUTER controller rescue (not the Loop's own model-error rescue) catches it.
      allow(Enliterator::Chat).to receive(:for_context).and_raise(StandardError.new("registry blew up"))

      post "/enliterator/chat/stream", params: { question: "hi" }

      expect(response.body).to include("event: error")
      data = error_event_data(response.body)
      expect(data).to eq("message" => "conversation failed")
      expect(data).not_to have_key("detail")
    end
  end

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

  it "with federation ON but chat_followups OFF, emits NO :followups event" do
    Enliterator.configuration.chat_federation = true
    Enliterator.configuration.chat_followups = nil
    allow(Enliterator).to receive(:llm).and_return(
      double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
        text: "ans\n\n#{Enliterator::Chat::Followups::SENTINEL}\nQ?", tool_calls: [],
        assistant_message: nil, tokens: {})))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response.body).not_to include("event: followups")
  end

  it "with chat_followups ON, emits a :followups event carrying the parsed questions" do
    Enliterator.configuration.chat_federation = true
    Enliterator.configuration.chat_followups = true
    allow(Enliterator).to receive(:llm).and_return(
      double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
        text: "ans\n\n#{Enliterator::Chat::Followups::SENTINEL}\nWhat next?", tool_calls: [],
        assistant_message: nil, tokens: {})))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response.body).to include("event: followups")
    expect(response.body).to include("What next?")
  ensure
    Enliterator.configuration.chat_followups = nil
  end

  it "degrades gracefully when federation is on but no agent is registered" do
    Enliterator.configuration.chat_federation = true
    Enliterator::Chat.reset!
    expect { post "/enliterator/chat/stream", params: { question: "hi" } }.not_to raise_error
    expect(response).to have_http_status(:ok)
  end

  it "logs a follow-up click-through when from_followup is present (flag on)" do
    Enliterator.configuration.chat_followups = true
    Enliterator.configuration.chat_federation = true
    llm_double = double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
      text: "ok", tool_calls: [], assistant_message: nil, tokens: {}))
    allow(Enliterator).to receive(:llm).and_return(llm_double)
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    allow(Enliterator.logger).to receive(:info)
    post "/enliterator/chat/stream", params: { question: "hi", from_followup: "1" }
    expect(Enliterator.logger).to have_received(:info).with(/followup_click/).at_least(:once)
  ensure
    Enliterator.configuration.chat_followups = nil
  end

  it "does NOT log a click-through for an ordinary submit (no from_followup param)" do
    # Guards against a refactor that logs on every request, not just follow-up clicks.
    Enliterator.configuration.chat_followups = true
    Enliterator.configuration.chat_federation = true
    llm_double = double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
      text: "ok", tool_calls: [], assistant_message: nil, tokens: {}))
    allow(Enliterator).to receive(:llm).and_return(llm_double)
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    allow(Enliterator.logger).to receive(:info)
    post "/enliterator/chat/stream", params: { question: "hi" }  # no from_followup
    expect(Enliterator.logger).not_to have_received(:info).with(/followup_click/)
  ensure
    Enliterator.configuration.chat_followups = nil
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
      annotateCites makeCiteChip buildCitePop wrapFirstMatch renderErrorCard
      scheduleRenderFederated renderFollowupButtons restoreStaticStarters
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
