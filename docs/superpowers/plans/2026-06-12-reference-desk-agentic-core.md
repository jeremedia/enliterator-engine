# v0.28 Reference Desk — Plan A: The Agentic Core (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the engine's authed `/enliterator/chat` an agentic, widget-rendering Reference Desk — a Frontdesk that triages and routes to a grounded CHDS-Theses specialist, working the v0.26 MCP tools across multiple rounds and rendering their structured results as inline HTML widgets — fully gated so that with no federation configured the chat is byte-identical to today.

**Architecture:** A shared service layer drives everything. `Chat::Agent` is a registered agent definition (persona + tool subset + tier + routes). `Chat::Loop` is the governed tool-calling loop (step cap + wall-clock budget; allow-list-before-dispatch; context-bearing-only grounding injection; `route_to` interception; visible failed-tool / cap-exhausted outcomes). `Chat::Widget` renders a tool's JSON result to self-contained HTML (pure functions). The Gateway adapter gains `converse_with_tools` (optional-multi-tool with results fed back, streamed). The existing `ConversationController#stream` is extended behind a `config.chat_federation` gate; with it off, the stream and view JS are unchanged.

This is **Plan A of two.** Plan B (the public accountless desk: net-new sessionless controller, link token, rate limit, per-surface scrub, leashed web tool) builds on this and follows once A lands. Design: `docs/designs/2026-06-12-reference-desk-design.md`.

**Tech Stack:** Ruby 3.4.5, Rails 8.1 engine (isolate_namespace), RSpec, the `openai` gem against the LiteLLM gateway, `ActionController::Live` SSE, vanilla inline JS (hard rule 2).

**Naming note (resolves a design ambiguity):** the design used `Chat::Agent` for both the agent *definition* and the *loop*. This plan splits them: `Enliterator::Chat::Agent` = the definition/registry; `Enliterator::Chat::Loop` = the loop. `Enliterator::Chat::Widget` = the renderers.

**Pre-flight (run once before Task 1):**

```bash
cd /Volumes/jer4TBv3/workspaces/work/enliterator
bundle exec rspec 2>&1 | tail -2   # confirm the v0.27 head is green before baselining
```
Expected: `NNN examples, 0 failures` (the design assumes ~537; record the actual number — it is the baseline the new examples add to).

---

## Task 1: `converse_with_tools` on the Gateway adapter

The new adapter primitive: offer N tools with `tool_choice: "auto"`, return EITHER a final assistant text OR the assistant's tool calls (all of them, with ids), and accept tool results fed back as `{role: "tool", tool_call_id:, content:}`. Streaming yields text deltas via a block. Built on the same `create`/`stream_raw` plumbing as `converse`.

**Files:**
- Modify: `app/services/enliterator/adapters/llm/base.rb` (add the abstract method)
- Modify: `app/services/enliterator/adapters/llm/gateway.rb` (implement it)
- Test: `spec/services/enliterator/adapters/llm/gateway_with_tools_spec.rb` (create)

- [ ] **Step 1: Write the failing test**

```ruby
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
    Struct.new("Calls") unless defined?(Struct::Calls)
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
    response = { "choices" => [ { "delta" => { "content" => "Hello " } } ] }
    final    = { "choices" => [ { "delta" => { "content" => "world" } } ] }
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/services/enliterator/adapters/llm/gateway_with_tools_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'converse_with_tools'`.

- [ ] **Step 3: Add the abstract method to Base**

In `app/services/enliterator/adapters/llm/base.rb`, beside the existing `converse`/`decide` `NotImplementedError` raisers, add:

```ruby
        # v0.28: optional-multi-tool completion. Offers +tools+ with tool_choice
        # "auto"; returns a ToolTurn (text OR tool_calls). Only the Gateway adapter
        # implements it — Null/Bedrock inherit this raise so a misconfigured
        # federation fails loudly, never silently.
        def converse_with_tools(messages:, tools:, tags: [], stream: false, &block)
          raise NotImplementedError, "#{self.class} does not implement converse_with_tools"
        end
```

- [ ] **Step 4: Implement it in Gateway**

In `app/services/enliterator/adapters/llm/gateway.rb`, add a result struct near the top of the class body (after `class Gateway < Base`) and the method after `decide`:

```ruby
        # The outcome of one converse_with_tools round: a final text answer, OR a
        # set of tool calls to execute and feed back. Exactly one is populated.
        ToolTurn = Struct.new(:text, :tool_calls, :assistant_message, :tokens, keyword_init: true)
```

```ruby
        # v0.28: one round of an optional-multi-tool conversation. With a block +
        # stream, text deltas are yielded and a text-only ToolTurn is returned.
        # Otherwise a non-streamed call returns either tool_calls (to execute) or
        # text (the final answer). The loop owns multi-round control flow.
        def converse_with_tools(messages:, tools:, tags: [], stream: false, &block)
          params = { model: @tier, messages: messages, tools: tools, tool_choice: "auto" }
          request_options = {}
          request_options[:extra_body] = { metadata: { tags: Array(tags) } } if Array(tags).any?

          if stream && block
            full = +""
            args = params.dup
            args[:request_options] = request_options unless request_options.empty?
            client.chat.completions.stream_raw(**args).each do |chunk|
              delta = extract_delta(chunk)
              next if delta.nil? || delta.empty?
              full << delta
              block.call(delta)
            end
            return ToolTurn.new(text: full, tool_calls: [], assistant_message: nil, tokens: {})
          end

          response =
            if request_options.empty?
              client.chat.completions.create(**params)
            else
              client.chat.completions.create(**params, request_options: request_options)
            end

          calls = all_tool_calls(response)
          if calls.any?
            ToolTurn.new(text: nil, tool_calls: calls, assistant_message: assistant_message_of(response),
                         tokens: extract_tokens(response))
          else
            ToolTurn.new(text: extract_message_content(response).to_s, tool_calls: [], assistant_message: nil,
                         tokens: extract_tokens(response))
          end
        end
```

Add these private helpers (after the existing `first_tool_call`):

```ruby
        # ALL tool calls on the first choice's message, normalized to
        # {id:, name:, arguments: Hash}. (first_tool_call returns only the first.)
        def all_tool_calls(response)
          message = message_of(first_choice(response))
          return [] unless message
          raw = if message.respond_to?(:tool_calls) then message.tool_calls
                elsif message.is_a?(Hash) then message[:tool_calls] || message["tool_calls"] end
          Array(raw).map do |tc|
            id = tc.respond_to?(:id) ? tc.id : (tc.is_a?(Hash) ? (tc[:id] || tc["id"]) : nil)
            fn = tc.respond_to?(:function) ? tc.function : (tc.is_a?(Hash) ? (tc[:function] || tc["function"]) : nil)
            name = fn.respond_to?(:name) ? fn.name : (fn.is_a?(Hash) ? (fn[:name] || fn["name"]) : nil)
            { id: id, name: name.to_s, arguments: parse_arguments(arguments_of(tc)) }
          end
        end

        # The assistant message, as a plain Hash with its tool_calls, for the loop
        # to append to messages before the tool-result messages (OpenAI requires the
        # assistant turn carrying tool_calls to precede the matching tool messages).
        def assistant_message_of(response)
          message = message_of(first_choice(response))
          calls = (message.respond_to?(:tool_calls) ? message.tool_calls :
                   (message.is_a?(Hash) ? (message[:tool_calls] || message["tool_calls"]) : [])) || []
          {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => Array(calls).map do |tc|
              id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc["id"])
              fn = tc.respond_to?(:function) ? tc.function : (tc[:function] || tc["function"])
              name = fn.respond_to?(:name) ? fn.name : (fn[:name] || fn["name"])
              { "id" => id, "type" => "function",
                "function" => { "name" => name, "arguments" => arguments_of(tc).to_s } }
            end
          }
        end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/enliterator/adapters/llm/gateway_with_tools_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 6: Commit**

```bash
git add app/services/enliterator/adapters/llm/base.rb app/services/enliterator/adapters/llm/gateway.rb spec/services/enliterator/adapters/llm/gateway_with_tools_spec.rb
git commit -m "v0.28: converse_with_tools — optional-multi-tool adapter primitive"
```

---

## Task 2: `Chat::Widget` — the renderer framework + the `record_entry` widget

A widget is a pure function `(tool_name, result_json) → HTML`. The framework dispatches by tool name to a renderer; an unknown tool falls back to a `<pre>` JSON dump (never raises). Self-contained HTML using the v0.19 component class names (no inline `<style>` here — the layout owns the CSS).

**Files:**
- Create: `app/services/enliterator/chat/widget.rb`
- Test: `spec/services/enliterator/chat/widget_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/enliterator/chat/widget_spec.rb
# frozen_string_literal: true
require "rails_helper"

# v0.28 — the widget renderers: pure functions of a tool's JSON result → self-
# contained HTML. record_entry renders the finding-aid card.
RSpec.describe Enliterator::Chat::Widget do
  it "renders record_entry as a card: label, claims grouped by facet, provenance fields" do
    result = {
      label: "A Thesis on Detention",
      claims_by_facet: { "significance" => [
        { id: 5, key: "contribution", value: "Argues X", confidence: 0.8, tier: "bedrock-sonnet",
          status: "live", audit_verdict: "supported" }
      ] },
      entry: "/enliterator/status/DocMetum/7"
    }
    html = described_class.render("record_entry", result)
    expect(html).to include("A Thesis on Detention")
    expect(html).to include("significance")
    expect(html).to include("contribution")
    expect(html).to include("Argues X")
    expect(html).to include("supported")           # the audit verdict shows
    expect(html).not_to include("<script")          # self-contained, inert
  end

  it "HTML-escapes claim values (no injection through tool data)" do
    result = { label: "T", claims_by_facet: { "f" => [ { key: "k", value: "<img src=x onerror=alert(1)>" } ] } }
    html = described_class.render("record_entry", result)
    expect(html).to include("&lt;img")
    expect(html).not_to include("<img src=x")
  end

  it "never raises on an unknown tool — falls back to a labeled JSON block" do
    html = described_class.render("no_such_tool", { a: 1 })
    expect(html).to include("no_such_tool")
    expect(html).to include("&quot;a&quot;").or include("\"a\"")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/services/enliterator/chat/widget_spec.rb`
Expected: FAIL — uninitialized constant `Enliterator::Chat::Widget`.

- [ ] **Step 3: Implement the framework + record_entry**

```ruby
# app/services/enliterator/chat/widget.rb
module Enliterator
  module Chat
    # v0.28: the widget renderers — pure functions (tool_name, result) → self-
    # contained HTML, using the v0.19 component classes (the layout owns the CSS).
    # Tool data is UNTRUSTED: every interpolated value is HTML-escaped. An unknown
    # tool never raises — it renders a labeled JSON block (rule 3: visible, not silent).
    module Widget
      module_function

      def render(tool_name, result)
        renderer = "render_#{tool_name}"
        respond_to?(renderer, true) ? send(renderer, result) : render_fallback(tool_name, result)
      end

      # --- helpers -----------------------------------------------------------
      def h(value) = ERB::Util.html_escape(value.to_s)

      def render_fallback(tool_name, result)
        %(<div class="enl-widget enl-widget--raw"><div class="enl-widget__head">#{h(tool_name)}</div>) +
          %(<pre class="enl-widget__json">#{h(JSON.pretty_generate(result))}</pre></div>)
      end

      # --- record_entry ------------------------------------------------------
      def render_record_entry(result)
        r = result.is_a?(Hash) ? result.transform_keys(&:to_sym) : {}
        facets = (r[:claims_by_facet] || {}).map do |facet, claims|
          rows = Array(claims).map { |c| claim_row(c) }.join
          %(<div class="enl-widget__facet"><div class="enl-widget__facet-name">#{h(facet)}</div>#{rows}</div>)
        end.join
        %(<div class="enl-widget enl-widget--record">) +
          %(<div class="enl-widget__head">#{h(r[:label])}</div>#{facets}</div>)
      end

      def claim_row(claim)
        c = claim.is_a?(Hash) ? claim.transform_keys(&:to_sym) : {}
        verdict = c[:audit_verdict] ? %( <span class="enl-claim__verdict">#{h(c[:audit_verdict])}</span>) : ""
        conf = c[:confidence] ? %( <span class="enl-claim__conf">#{h(c[:confidence])}</span>) : ""
        %(<div class="enl-claim"><span class="enl-claim__key">#{h(c[:key])}</span>: ) +
          %(<span class="enl-claim__value">#{h(c[:value])}</span>#{conf}#{verdict}</div>)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/enliterator/chat/widget_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 5: Commit**

```bash
git add app/services/enliterator/chat/widget.rb spec/services/enliterator/chat/widget_spec.rb
git commit -m "v0.28: Chat::Widget framework + record_entry renderer (escaped, unknown-safe)"
```

---

## Task 3: `Chat::Widget` — provenance, trajectory, accuracy renderers

Three more renderers on the Task-2 framework. Each is a focused pure function over its tool's result shape (from `app/services/enliterator/mcp/tools/{provenance,trajectory,accuracy}.rb`).

**Files:**
- Modify: `app/services/enliterator/chat/widget.rb`
- Test: `spec/services/enliterator/chat/widget_provenance_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/enliterator/chat/widget_provenance_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Widget do
  it "renders provenance as a chain: claim → visit (tier/model/at) → audits" do
    result = { claim: { key: "contribution", value: "Argues X" },
               visit: { tier: "bedrock-sonnet", model: "stub", at: "2026-06-12" },
               audits: [ { source: "examiner", verdict: "supported", rationale: "the source says so" } ] }
    html = described_class.render("provenance", result)
    expect(html).to include("contribution")
    expect(html).to include("bedrock-sonnet")
    expect(html).to include("examiner")
    expect(html).to include("supported")
  end

  it "renders accuracy as a per-facet/tier table" do
    result = { by_facet_and_tier: [ { facet: "authorship", tier: "cheap", audited: 20, supported: 19 } ],
               anchor_agreement: { rate: 0.95 } }
    html = described_class.render("accuracy", result)
    expect(html).to include("authorship")
    expect(html).to include("19")
    expect(html).to include("95").or include("0.95")
  end

  it "renders trajectory as ordered steps with per-step tier and ops" do
    result = { facet: "significance", steps: [
      { at: "2026-06-10", tier: "quality", ops: { "added" => 2, "updated" => 1 } },
      { at: "2026-06-12", tier: "bedrock-sonnet", ops: { "updated" => 3 } }
    ] }
    html = described_class.render("trajectory", result)
    expect(html).to include("significance")
    expect(html.scan("enl-step").size).to be >= 2
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/enliterator/chat/widget_provenance_spec.rb`
Expected: FAIL — the renderers fall back to the JSON block, so the structural assertions (`enl-step`, table cells) fail.

- [ ] **Step 3: Add the three renderers**

Append inside `module Widget` in `app/services/enliterator/chat/widget.rb`:

```ruby
      # --- provenance --------------------------------------------------------
      def render_provenance(result)
        r = symize(result); claim = symize(r[:claim]); visit = symize(r[:visit])
        audits = Array(r[:audits]).map do |a|
          a = symize(a)
          %(<li class="enl-prov__audit"><b>#{h(a[:source])}</b>: #{h(a[:verdict])} — #{h(a[:rationale])}</li>)
        end.join
        %(<div class="enl-widget enl-widget--prov">) +
          %(<div class="enl-prov__claim">#{h(claim[:key])}: #{h(claim[:value])}</div>) +
          %(<div class="enl-prov__visit">#{h(visit[:tier])} · #{h(visit[:model])} · #{h(visit[:at])}</div>) +
          %(<ul class="enl-prov__audits">#{audits}</ul></div>)
      end

      # --- accuracy ----------------------------------------------------------
      def render_accuracy(result)
        r = symize(result)
        rows = Array(r[:by_facet_and_tier]).map do |row|
          row = symize(row)
          %(<tr><td>#{h(row[:facet])}</td><td>#{h(row[:tier])}</td>) +
            %(<td>#{h(row[:audited])}</td><td>#{h(row[:supported])}</td></tr>)
        end.join
        anchor = symize(r[:anchor_agreement])[:rate]
        %(<div class="enl-widget enl-widget--accuracy">) +
          %(<table class="enl-accuracy"><thead><tr><th>facet</th><th>tier</th><th>audited</th><th>supported</th></tr></thead>) +
          %(<tbody>#{rows}</tbody></table>) +
          (anchor ? %(<div class="enl-accuracy__anchor">anchor agreement: #{h(anchor)}</div>) : "") + %(</div>)
      end

      # --- trajectory --------------------------------------------------------
      def render_trajectory(result)
        r = symize(result)
        steps = Array(r[:steps]).map do |s|
          s = symize(s)
          ops = (s[:ops] || {}).map { |k, v| "#{h(k)} #{h(v)}" }.join(", ")
          %(<li class="enl-step"><span class="enl-step__at">#{h(s[:at])}</span> ) +
            %(<span class="enl-step__tier">#{h(s[:tier])}</span> <span class="enl-step__ops">#{ops}</span></li>)
        end.join
        %(<div class="enl-widget enl-widget--traj"><div class="enl-widget__head">#{h(r[:facet])}</div>) +
          %(<ol class="enl-traj">#{steps}</ol></div>)
      end
```

Add the `symize` helper next to `h`:

```ruby
      def symize(value) = value.is_a?(Hash) ? value.transform_keys(&:to_sym) : {}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/enliterator/chat/widget_provenance_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 5: Commit**

```bash
git add app/services/enliterator/chat/widget.rb spec/services/enliterator/chat/widget_provenance_spec.rb
git commit -m "v0.28: provenance, accuracy, trajectory widget renderers"
```

---

## Task 4: `Chat::Widget` — search, subject_search, quote, connections renderers

The remaining four renderers, same framework. (record_entry covers the richest shape; these are list/passage/edge renderers.)

**Files:**
- Modify: `app/services/enliterator/chat/widget.rb`
- Test: `spec/services/enliterator/chat/widget_lists_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/enliterator/chat/widget_lists_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Widget do
  it "renders search results as a card list (label, type, excerpt, counts)" do
    result = { results: [ { label: "A", type: "DocMetum", id: "7", excerpt: "about detention",
                            claim_count: 12, visit_count: 3 } ] }
    html = described_class.render("search", result)
    expect(html).to include("A")
    expect(html).to include("about detention")
    expect(html).to include("12")
  end

  it "renders quote with the located passage and a not-located fallback flag" do
    located = described_class.render("quote", { located: true, passage: "the tabulation showed" })
    expect(located).to include("the tabulation showed")
    lost = described_class.render("quote", { located: false, passage: "(head of source)" })
    expect(lost).to include("not located").or include("could not locate")
    expect(lost).to include("(head of source)")
  end

  it "renders connections as a typed-edge list and labels a degraded/empty neighbor set" do
    result = { edges: [ { key: "cited_works", target: "Hoffman", weight: 1 } ],
               neighbors: [], neighbors_state: "no_embedding" }
    html = described_class.render("connections", result)
    expect(html).to include("cited_works")
    expect(html).to include("Hoffman")
    expect(html).to include("no embedding").or include("not embedded")  # degraded label, not silent empty
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/enliterator/chat/widget_lists_spec.rb`
Expected: FAIL — renderers fall back; structural assertions fail.

- [ ] **Step 3: Add the four renderers**

Append inside `module Widget`:

```ruby
      # --- search / subject_search (same card-list shape) ---------------------
      def render_search(result)
        cards = Array(symize(result)[:results]).map do |item|
          i = symize(item)
          counts = [ ("#{h(i[:claim_count])} claims" if i[:claim_count]),
                     ("#{h(i[:visit_count])} visits" if i[:visit_count]) ].compact.join(" · ")
          %(<li class="enl-result"><div class="enl-result__label">#{h(i[:label])} ) +
            %(<span class="enl-result__type">#{h(i[:type])}</span></div>) +
            %(<div class="enl-result__excerpt">#{h(i[:excerpt])}</div>) +
            %(<div class="enl-result__counts">#{counts}</div></li>)
        end.join
        %(<div class="enl-widget enl-widget--results"><ul class="enl-results">#{cards}</ul></div>)
      end
      def render_subject_search(result) = render_search(result)

      # --- quote -------------------------------------------------------------
      def render_quote(result)
        r = symize(result)
        if r[:located] == false
          %(<div class="enl-widget enl-widget--quote enl-widget--quote-unlocated">) +
            %(<div class="enl-quote__flag">passage not located — showing head of source</div>) +
            %(<blockquote class="enl-quote">#{h(r[:passage])}</blockquote></div>)
        else
          %(<div class="enl-widget enl-widget--quote"><blockquote class="enl-quote">#{h(r[:passage])}</blockquote></div>)
        end
      end

      # --- connections -------------------------------------------------------
      def render_connections(result)
        r = symize(result)
        edges = Array(r[:edges]).map do |e|
          e = symize(e)
          %(<li class="enl-edge"><span class="enl-edge__key">#{h(e[:key])}</span> → #{h(e[:target])}</li>)
        end.join
        neighbors = Array(r[:neighbors])
        nb = if neighbors.empty? && r[:neighbors_state].to_s != "" && r[:neighbors_state].to_s != "ok"
               %(<div class="enl-edge__degraded">neighbors unavailable (#{h(r[:neighbors_state])})</div>)
             else
               neighbors.map { |n| n = symize(n); %(<li class="enl-neighbor">#{h(n[:label])}</li>) }.join
             end
        %(<div class="enl-widget enl-widget--conn"><ul class="enl-edges">#{edges}</ul>#{nb}</div>)
      end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/enliterator/chat/widget_lists_spec.rb`
Expected: PASS (3 examples).

> NOTE for Plan B / the loop integration: `connections` returns `[]` neighbors when the record has no stored embedding (not when the embedder is down — verified `connections.rb`). The `neighbors_state` key the renderer reads is NEW — Task 7 wires the tool/loop to set it (`"ok"`, `"no_embedding"`, `"not_in_atlas"`) so the widget can label a degraded/empty result instead of asserting "none."

- [ ] **Step 5: Commit**

```bash
git add app/services/enliterator/chat/widget.rb spec/services/enliterator/chat/widget_lists_spec.rb
git commit -m "v0.28: search/subject_search/quote/connections widget renderers"
```

---

## Task 5: `Chat::Agent` — the agent definition + registry + tier validation

A registered agent: name, grounding context key (nil = Frontdesk), system prompt, allowed tool names, tier, and `routes_to`. Registration VALIDATES that the tier resolves to a Gateway adapter responding to `converse_with_tools` (the dedicated agent-tier check — NOT `Policy#validate!`, which sees a different set).

**Files:**
- Create: `app/services/enliterator/chat/agent.rb`
- Modify: `lib/enliterator.rb` (add `config.chat_federation` accessor + `Chat.register`/`Chat.agents`)
- Test: `spec/services/enliterator/chat/agent_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/enliterator/chat/agent_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Agent do
  # A fake adapter that DOES respond to converse_with_tools (the Gateway contract).
  let(:capable) { Class.new { def converse_with_tools(**) = nil }.new }
  # A fake that does NOT (the direct-Bedrock trap).
  let(:incapable) { Class.new { def converse(**) = nil }.new }

  before { Enliterator::Chat.reset! }
  after  { Enliterator::Chat.reset! }

  it "registers a frontdesk (nil grounding) and a specialist, resolvable by name and by context" do
    allow(Enliterator).to receive(:llm).and_return(capable)
    Enliterator::Chat.register(name: "Frontdesk", grounding: nil, system_prompt: "triage",
                               tools: %w[search record_entry], tier: "cheap", routes_to: %w[CHDS])
    Enliterator::Chat.register(name: "CHDS", grounding: "chds-theses", system_prompt: "advise",
                               tools: %w[search record_entry provenance], tier: "bedrock-sonnet")
    expect(Enliterator::Chat.frontdesk.name).to eq("Frontdesk")
    expect(Enliterator::Chat.for_context("chds-theses").name).to eq("CHDS")
    expect(Enliterator::Chat.for_context("unknown")).to eq(Enliterator::Chat.frontdesk)  # fallback
  end

  it "REFUSES to register an agent whose tier resolves to an adapter lacking converse_with_tools" do
    allow(Enliterator).to receive(:llm).with(tier: "bad").and_return(incapable)
    expect {
      Enliterator::Chat.register(name: "X", grounding: nil, system_prompt: "p", tools: [], tier: "bad")
    }.to raise_error(Enliterator::ConfigurationError, /converse_with_tools/)
  end

  it "an agent exposes its OpenAI tool defs from Mcp.listing filtered to its allow-list" do
    allow(Enliterator).to receive(:llm).and_return(capable)
    a = Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                                   tools: %w[search], tier: "cheap")
    names = a.tool_defs.map { |d| d.dig("function", "name") }
    expect(names).to eq(%w[search])
    expect(a.allows?("search")).to be(true)
    expect(a.allows?("flag_claim")).to be(false)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/enliterator/chat/agent_spec.rb`
Expected: FAIL — uninitialized constant `Enliterator::Chat`.

- [ ] **Step 3: Implement `Chat::Agent` + the registry**

```ruby
# app/services/enliterator/chat/agent.rb
module Enliterator
  module Chat
    module_function

    # The registry. Process-level, reset in specs. config.chat_federation gates
    # whether the controller uses it at all (back-compat).
    def registry = (@registry ||= {})
    def reset!   = (@registry = {})
    def agents   = registry.values
    def frontdesk = registry.values.find { |a| a.grounding.nil? }
    def for_context(key) = registry.values.find { |a| a.grounding == key.to_s } || frontdesk

    # Register an agent. Validates the tier resolves to a converse_with_tools-capable
    # adapter NOW (fail-fast at registration, never mid-stream).
    def register(name:, grounding:, system_prompt:, tools:, tier:, routes_to: [])
      adapter = Enliterator.llm(tier: tier)
      unless adapter.respond_to?(:converse_with_tools)
        raise Enliterator::ConfigurationError,
              "Chat agent #{name.inspect} tier #{tier.inspect} resolves to #{adapter.class} " \
              "which does not implement converse_with_tools (require the gateway; check the alias is advertised)"
      end
      registry[name.to_s] = Agent.new(name: name.to_s, grounding: grounding&.to_s, system_prompt: system_prompt,
                                      tools: Array(tools).map(&:to_s), tier: tier.to_s,
                                      routes_to: Array(routes_to).map(&:to_s))
    end

    # An agent definition.
    class Agent
      attr_reader :name, :grounding, :system_prompt, :tools, :tier, :routes_to
      def initialize(name:, grounding:, system_prompt:, tools:, tier:, routes_to:)
        @name = name; @grounding = grounding; @system_prompt = system_prompt
        @tools = tools; @tier = tier; @routes_to = routes_to
      end

      def allows?(tool_name) = tools.include?(tool_name.to_s)

      # The OpenAI function defs for this agent's tools, from the shared Mcp.listing,
      # filtered to the allow-list (read-only enforcement starts at what's offered).
      def tool_defs
        Enliterator::Mcp.listing.select { |t| allows?(t[:name]) }.map do |t|
          { "type" => "function",
            "function" => { "name" => t[:name], "description" => t[:description], "parameters" => t[:inputSchema] } }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Add the config accessor**

In `lib/enliterator.rb`, in the `Configuration` class, add beside the other `attr_accessor`s:

```ruby
    # v0.28: gate the agentic Reference Desk. Off (nil/false) ⇒ /enliterator/chat
    # is the byte-identical single-shot RAG. On ⇒ the controller drives Chat::Loop.
    attr_accessor :chat_federation
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/services/enliterator/chat/agent_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 6: Commit**

```bash
git add app/services/enliterator/chat/agent.rb lib/enliterator.rb spec/services/enliterator/chat/agent_spec.rb
git commit -m "v0.28: Chat::Agent registry + fail-fast tier validation + config.chat_federation"
```

---

## Task 6: `Chat::Loop` — the governed agentic loop (core: dispatch, allow-list, grounding, route_to)

The heart. One turn: resolve the active agent, loop model↔tools under a step cap. Each round: `route_to` is intercepted FIRST (switch agent, emit a `:handoff` event, never dispatch); remaining tool calls are allow-list-checked BEFORE `Mcp.dispatch`; context is injected into a call's args only when the model omits it AND the tool's schema declares `context`. Tool results are rendered to widgets (emitted) and fed back. Events are emitted via an injected sink (the controller passes an SSE writer; specs pass an array).

**Files:**
- Create: `app/services/enliterator/chat/loop.rb`
- Test: `spec/services/enliterator/chat/loop_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/enliterator/chat/loop_spec.rb
# frozen_string_literal: true
require "rails_helper"

# v0.28 — the loop's enforcement boundary is the safety-critical surface.
RSpec.describe Enliterator::Chat::Loop do
  # A scripted adapter: returns queued ToolTurns in order. Each is either tool_calls
  # or final text.
  class ScriptedLLM
    TT = Enliterator::Adapters::LLM::Gateway::ToolTurn
    def initialize(*turns) = (@turns = turns)
    def converse_with_tools(messages:, tools:, **)
      t = @turns.shift
      t.is_a?(TT) ? t : TT.new(text: t.to_s, tool_calls: [], assistant_message: nil, tokens: {})
    end
  end
  def calls(*list) = Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
    text: nil, tool_calls: list, assistant_message: { "role" => "assistant", "tool_calls" => [] }, tokens: {})

  let(:events) { [] }
  let(:sink)   { ->(event, data) { events << [ event, data ] } }

  before do
    Enliterator::Chat.reset!
    allow(Enliterator).to receive(:llm).and_return(double(converse_with_tools: nil))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search provenance], tier: "cheap", routes_to: %w[CHDS])
    Enliterator::Chat.register(name: "CHDS", grounding: "chds-theses", system_prompt: "advise",
                               tools: %w[search provenance], tier: "cheap")
  end
  after { Enliterator::Chat.reset! }

  def run(llm, agent: Enliterator::Chat.frontdesk)
    described_class.new(agent: agent, llm: llm, sink: sink, step_cap: 4).run("hello")
  end

  it "REFUSES a tool not on the active agent's allow-list, before dispatch (read-only enforcement)" do
    expect(Enliterator::Mcp).not_to receive(:dispatch)
    run(ScriptedLLM.new(calls({ id: "1", name: "flag_claim", arguments: {} }), "done"))
    expect(events.map(&:first)).to include(:tool_call_error)
    err = events.find { |e| e.first == :tool_call_error }
    expect(err.last[:message]).to match(/not (allowed|available)/i)
  end

  it "intercepts route_to FIRST (never dispatches it) and switches the active agent" do
    expect(Enliterator::Mcp).not_to receive(:dispatch)
    run(ScriptedLLM.new(calls({ id: "1", name: "route_to", arguments: { "agent" => "CHDS" } }), "now at CHDS"))
    handoff = events.find { |e| e.first == :handoff }
    expect(handoff.last[:to]).to eq("CHDS")
  end

  it "injects the desk context only for context-bearing tools the model left unscoped" do
    captured = []
    allow(Enliterator::Mcp).to receive(:dispatch) { |name, args| captured << [ name, args ]; { label: "x" } }
    chds = Enliterator::Chat.for_context("chds-theses")
    # search HAS context; provenance does NOT
    run(ScriptedLLM.new(calls({ id: "1", name: "search", arguments: { "q" => "x" } },
                              { id: "2", name: "provenance", arguments: { "claim_id" => 5 } }), "done"),
        agent: chds)
    search_args = captured.find { |c| c.first == "search" }.last
    prov_args   = captured.find { |c| c.first == "provenance" }.last
    expect(search_args["context"]).to eq("chds-theses")   # injected (omitted + context-bearing)
    expect(prov_args).not_to have_key("context")          # NOT injected (no context property)
  end

  it "honors a model-supplied context (the 'not walled' widen)" do
    captured = []
    allow(Enliterator::Mcp).to receive(:dispatch) { |name, args| captured << args; { label: "x" } }
    chds = Enliterator::Chat.for_context("chds-theses")
    run(ScriptedLLM.new(calls({ id: "1", name: "search", arguments: { "q" => "x", "context" => "crs-reports" } }), "done"), agent: chds)
    expect(captured.first["context"]).to eq("crs-reports")
  end

  it "emits a tool_call_result (widget) and feeds the result back, ending on the final answer" do
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ label: "A Thesis", claims_by_facet: {} })
    run(ScriptedLLM.new(calls({ id: "1", name: "search", arguments: { "q" => "x" } }), "Here is what I found."))
    widget = events.find { |e| e.first == :tool_call_result }
    expect(widget.last[:html]).to include("A Thesis")
    expect(events.last).to eq([ :done, {} ])
  end

  it "stops at the step cap with a visible budget message (rule 3), never silently" do
    looping = Array.new(10) { calls({ id: "1", name: "search", arguments: { "q" => "x" } }) }
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ label: "x", claims_by_facet: {} })
    run(ScriptedLLM.new(*looping))
    budget = events.find { |e| e.first == :token && e.last[:t].to_s.match?(/step budget/i) }
    expect(budget).not_to be_nil
    expect(events.last).to eq([ :done, {} ])
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/enliterator/chat/loop_spec.rb`
Expected: FAIL — uninitialized constant `Enliterator::Chat::Loop`.

- [ ] **Step 3: Implement the loop**

```ruby
# app/services/enliterator/chat/loop.rb
module Enliterator
  module Chat
    # v0.28: the governed agentic loop. The LOOP — not the model — is the
    # enforcement boundary (allow-list before dispatch, grounding injection,
    # route_to interception). Events go to an injected sink (controller: SSE writer;
    # specs: an array). One turn per #run.
    class Loop
      ROUTE_TO = "route_to".freeze

      def initialize(agent:, llm: nil, sink:, step_cap: 4, context_resolver: nil)
        @agent   = agent
        @llm     = llm
        @sink    = sink
        @step_cap = step_cap
        # Maps a context key → the value tools expect (the key string). Server-side,
        # never the cookie. Default: identity.
        @resolve = context_resolver || ->(key) { key }
      end

      # Drive the turn. Returns nothing meaningful; everything is emitted via the sink.
      def run(question)
        messages = [ { role: "system", content: @agent.system_prompt },
                     { role: "user", content: question.to_s } ]
        steps = 0
        loop do
          if steps >= @step_cap
            emit(:token, t: "I reached my step budget — here is what I have so far.")
            Enliterator.logger&.info("[enliterator] chat loop hit step cap (#{@step_cap}) agent=#{@agent.name}")
            break
          end
          steps += 1
          turn = llm.converse_with_tools(messages: messages, tools: tool_defs_with_route)
          if turn.tool_calls.empty?
            emit(:token, t: turn.text.to_s)
            break
          end
          messages << (turn.assistant_message || { "role" => "assistant", "content" => nil })
          stop = handle_calls(turn.tool_calls, messages)
          break if stop
        end
        emit(:done, {})
      end

      private

      def llm
        @llm ||= Enliterator.llm(tier: @agent.tier)
      end

      # route_to schema is injected here, never from Mcp.listing. Only for agents
      # that actually route.
      def tool_defs_with_route
        defs = @agent.tool_defs
        if @agent.routes_to.any?
          defs += [ { "type" => "function", "function" => {
            "name" => ROUTE_TO, "description" => "Hand off to a specialist desk.",
            "parameters" => { "type" => "object", "required" => [ "agent" ],
                              "properties" => { "agent" => { "type" => "string",
                                                             "enum" => @agent.routes_to } } } } } ]
        end
        defs
      end

      # Returns true if the loop should stop after these calls (a handoff continues;
      # only a fatal has-no-more is signalled elsewhere). Appends tool-result messages.
      def handle_calls(calls, messages)
        calls.each do |call|
          # 1. route_to FIRST — intercepted, never dispatched.
          if call[:name] == ROUTE_TO
            target = call.dig(:arguments, "agent")
            agent = Enliterator::Chat.registry[target.to_s]
            if agent.nil?
              tool_error(call, messages, "cannot route to #{target.inspect}")
            else
              @agent = agent
              emit(:handoff, to: agent.name)
              messages << tool_result_message(call, { routed_to: agent.name })
            end
            next
          end
          # 2. allow-list BEFORE dispatch (read-only enforcement).
          unless @agent.allows?(call[:name])
            tool_error(call, messages, "tool #{call[:name].inspect} is not available at this desk")
            next
          end
          # 3. grounding injection (context-bearing tools, model omitted).
          args = ground(call)
          begin
            result = Enliterator::Mcp.dispatch(call[:name], args)
            emit(:tool_call_start, name: call[:name])
            emit(:tool_call_result, name: call[:name], html: Enliterator::Chat::Widget.render(call[:name], result))
            messages << tool_result_message(call, result)
          rescue StandardError => e
            tool_error(call, messages, "couldn't consult #{call[:name]}: #{e.message}")
          end
        end
        false
      end

      def ground(call)
        args = (call[:arguments] || {}).dup
        if @agent.grounding && !args.key?("context") && tool_takes_context?(call[:name])
          args["context"] = @resolve.call(@agent.grounding)
        end
        args
      end

      def tool_takes_context?(name)
        tool = Enliterator::Mcp.find_tool(name)
        tool && (tool.input_schema["properties"] || {}).key?("context")
      end

      def tool_result_message(call, result)
        { "role" => "tool", "tool_call_id" => call[:id], "content" => result.to_json }
      end

      def tool_error(call, messages, message)
        emit(:tool_call_error, name: call[:name], message: message)
        Enliterator.logger&.warn("[enliterator] chat tool error: #{message}")
        messages << tool_result_message(call, { error: message })
      end

      def emit(event, data) = @sink.call(event, data)
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/enliterator/chat/loop_spec.rb`
Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
git add app/services/enliterator/chat/loop.rb spec/services/enliterator/chat/loop_spec.rb
git commit -m "v0.28: Chat::Loop — allow-list, grounding, route_to interception, step cap"
```

---

## Task 7: Loop hardening — wall-clock budget + connections degraded-state labeling

Add the per-turn wall-clock budget (the step cap bounds round-trips, not latency) and surface `connections`'s empty-vs-degraded distinction so the widget can label it (Task 4's `neighbors_state`).

**Files:**
- Modify: `app/services/enliterator/chat/loop.rb`
- Modify: `app/services/enliterator/mcp/tools/connections.rb`
- Test: `spec/services/enliterator/chat/loop_budget_spec.rb`, `spec/services/enliterator/mcp/tools/connections_state_spec.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/services/enliterator/chat/loop_budget_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Loop do
  include ActiveSupport::Testing::TimeHelpers
  TT = Enliterator::Adapters::LLM::Gateway::ToolTurn

  it "stops with a visible message when the per-turn wall-clock budget is exceeded between rounds" do
    Enliterator::Chat.reset!
    allow(Enliterator).to receive(:llm).and_return(double(converse_with_tools: nil))
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p", tools: %w[search], tier: "cheap")
    events = []
    # Each round advances the clock 40s; budget 60s ⇒ stops after the 2nd round check.
    llm = Object.new
    def llm.converse_with_tools(**)
      Enliterator::Chat::LoopBudgetClock.advance
      TT.new(text: nil, tool_calls: [ { id: "1", name: "search", arguments: { "q" => "x" } } ],
             assistant_message: { "role" => "assistant", "tool_calls" => [] }, tokens: {})
    end
    allow(Enliterator::Mcp).to receive(:dispatch).and_return({ label: "x", claims_by_facet: {} })
    sink = ->(e, d) { events << [ e, d ] }
    described_class.new(agent: Enliterator::Chat.frontdesk, llm: llm, sink: sink,
                        step_cap: 10, wall_budget: 60).run("hi")
    budget = events.find { |e| e.first == :token && e.last[:t].to_s.match?(/time budget/i) }
    expect(budget).not_to be_nil
  ensure
    Enliterator::Chat.reset!
  end
end
```

```ruby
# spec/services/enliterator/mcp/tools/connections_state_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Mcp::Tools::Connections do
  it "labels neighbors_state 'no_embedding' when the record has no stored primary embedding" do
    w = Widget.create!(title: "Unembedded", body: "b")   # dummy host record, no embedding row
    out = Enliterator::Mcp.dispatch("connections", { "type" => "Widget", "id" => w.id.to_s })
    expect(out[:neighbors]).to eq([])
    expect(out[:neighbors_state]).to eq("no_embedding")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/enliterator/chat/loop_budget_spec.rb spec/services/enliterator/mcp/tools/connections_state_spec.rb`
Expected: FAIL — `wall_budget:` not accepted; `neighbors_state` absent.

- [ ] **Step 3a: Add the wall-clock budget to the loop**

In `loop.rb`, add a tiny injectable clock (so specs can advance it without real sleeps) and the budget. Change `initialize` and `run`:

```ruby
      def initialize(agent:, llm: nil, sink:, step_cap: 4, wall_budget: 90, context_resolver: nil, clock: nil)
        @agent = agent; @llm = llm; @sink = sink; @step_cap = step_cap
        @wall_budget = wall_budget
        @resolve = context_resolver || ->(key) { key }
        @clock = clock || LoopBudgetClock
      end
```

In `run`, capture the start and check between rounds (add to the top of the loop body, before the step-cap check):

```ruby
        started = @clock.now
        loop do
          if @clock.now - started > @wall_budget
            emit(:token, t: "I reached my time budget — here is what I have so far.")
            Enliterator.logger&.info("[enliterator] chat loop hit wall budget (#{@wall_budget}s) agent=#{@agent.name}")
            break
          end
          # ... existing step-cap check + body ...
```

Add the clock module at the bottom of `loop.rb` (outside the `Loop` class, inside `module Chat`):

```ruby
    # Injectable monotonic clock so specs can advance time without sleeping.
    # NOTE: the loop's wall budget is a BETWEEN-ROUNDS check; it cannot interrupt a
    # single in-flight gateway call. Plan B's public desk sets a SHORTER per-call
    # gateway timeout (the global gateway_timeout is 180s) so one round can't blow
    # the turn budget by minutes. See the design's wall-clock note.
    module LoopBudgetClock
      module_function
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def advance(_ = nil) = nil  # real clock; specs replace this module via clock:
    end
```

For the spec's `LoopBudgetClock.advance`, the test injects its own clock — adjust the spec to pass `clock:` instead of mutating the module. (Replace the spec's `def llm.converse_with_tools` clock-advance with a stub clock passed via `clock:` that returns increasing values. Implementer: a `FakeClock` returning `[0, 40, 80, ...]` on successive `now` calls, passed as `clock: FakeClock.new`.)

- [ ] **Step 3b: Add `neighbors_state` to the connections tool**

In `app/services/enliterator/mcp/tools/connections.rb`, where `neighbors_for` returns `[]` for a missing embedding, have the tool's `call` set `neighbors_state`: `"no_embedding"` when the record has no `kind: "primary"` embedding, `"not_in_atlas"` when the record produced no edges and isn't a node, else `"ok"`. Concretely, in the result hash the tool returns, add:

```ruby
          neighbors_state: neighbors_state(record),
```

and a private helper:

```ruby
        def neighbors_state(record)
          return "no_embedding" if record.enliterator_embeddings.find_by(kind: "primary")&.embedding.nil?
          "ok"
        end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/services/enliterator/chat/loop_budget_spec.rb spec/services/enliterator/mcp/tools/connections_state_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/enliterator/chat/loop.rb app/services/enliterator/mcp/tools/connections.rb spec/services/enliterator/chat/loop_budget_spec.rb spec/services/enliterator/mcp/tools/connections_state_spec.rb
git commit -m "v0.28: loop wall-clock budget + connections degraded-state labeling"
```

---

## Task 8: Cache `Audit.accuracy` (keyed on audit writes, not heartbeat id)

`collection_overview` runs `Audit.accuracy` inline on the first turn; it's uncached and grows with the audit set. Cache it in `Rails.cache`, keyed on `max(audits.updated_at)` + count so it invalidates on human/agent audit writes between heartbeats (the heartbeat-id key the other rollups use would go stale after a `/review` verdict).

**Files:**
- Modify: `app/models/enliterator/audit.rb`
- Test: `spec/models/enliterator/audit_cache_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/enliterator/audit_cache_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Audit do
  around { |ex| old = Rails.cache; Rails.cache = ActiveSupport::Cache::MemoryStore.new; ex.run; Rails.cache = old }

  it "serves accuracy from cache and invalidates when a new audit is filed" do
    w = Widget.create!(title: "T", body: "b")
    v = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    c = w.enliterator_claims.create!(key: "topic", value: "x", status: "live", visit: v)
    first = described_class.accuracy_cached
    expect(first).to eq(described_class.accuracy_cached)   # second call: same object from cache
    described_class.create!(claim: c, source: "human", auditor: "j", verdict: "supported", rationale: "r")
    expect(described_class.accuracy_cached).not_to eq(first)  # key moved on the write
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/models/enliterator/audit_cache_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'accuracy_cached'`.

- [ ] **Step 3: Implement `accuracy_cached`**

In `app/models/enliterator/audit.rb`, add:

```ruby
    # v0.28: cached accuracy for the hot first-turn path (collection_overview /
    # the accuracy tool). Keyed on the audit set's last write + count — NOT the
    # heartbeat id — because audits are filed out-of-band (human /review, agent
    # flag_claim) between beats; a heartbeat-id key would serve a stale number.
    def self.accuracy_cached
      key = [ "enliterator-accuracy", maximum(:updated_at)&.to_i, count ]
      Rails.cache.fetch(key, expires_in: 5.minutes) { accuracy }
    end
```

- [ ] **Step 4: Point the hot callers at the cache**

In `app/services/enliterator/mcp/tools/accuracy.rb` and `app/services/enliterator/mcp/tools/collection_overview.rb`, replace `Enliterator::Audit.accuracy` with `Enliterator::Audit.accuracy_cached`. (Leave the Atlas/Synopsis rollups as-is; only accuracy was uncached.)

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/models/enliterator/audit_cache_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/models/enliterator/audit.rb app/services/enliterator/mcp/tools/accuracy.rb app/services/enliterator/mcp/tools/collection_overview.rb spec/models/enliterator/audit_cache_spec.rb
git commit -m "v0.28: cache Audit.accuracy on audit-write key (hot first-turn path)"
```

---

## Task 9: Transport — drive the loop from the authed controller, federation-gated + byte-identical

Wire `Chat::Loop` into `ConversationController#stream` behind `config.chat_federation`. With it off, the existing single-shot path runs unchanged (byte-identical). With it on, the loop drives, emitting the new lowercase events alongside the kept `token`/`provenance`/`done`. The view ships widget-aware JS only inside a federation-gated server-rendered branch.

**Files:**
- Modify: `app/controllers/enliterator/conversation_controller.rb`
- Modify: `app/views/enliterator/conversation/index.html.erb`
- Test: `spec/requests/enliterator/conversation_federation_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/requests/enliterator/conversation_federation_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe "Conversation federation", type: :request do
  after { Enliterator.configuration.chat_federation = nil; Enliterator::Chat.reset! }

  it "with federation OFF, the stream uses the single-shot path (no widget/handoff events)" do
    Enliterator.configuration.chat_federation = nil
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("event: tool_call_result")
    expect(response.body).not_to include("event: handoff")
  end

  it "with federation ON, the stream drives the loop (emits a widget then done)" do
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
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/enliterator/conversation_federation_spec.rb`
Expected: FAIL — the ON example sees no loop output (the controller still runs the single-shot path).

- [ ] **Step 3: Branch the controller's `stream`**

In `conversation_controller.rb`, replace the body of `stream` (between the header lines and the `rescue`) with a gate. Keep the existing single-shot block verbatim in the `else`:

```ruby
    def stream
      response.headers["Content-Type"]      = "text/event-stream"
      response.headers["Cache-Control"]     = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      if Enliterator.configuration.chat_federation
        agent = Enliterator::Chat.for_context(current_context&.key)
        Enliterator::Chat::Loop.new(agent: agent, sink: method(:sse)).run(params[:question].to_s)
      else
        provenance = Enliterator::Conversation.new(context: current_context).reply(
          question: params[:question].to_s, history: parse_history, stream: true
        ) { |delta| sse(:token, t: delta) }
        sse(:provenance, records: provenance[:records], tier: provenance[:tier],
                         degraded: provenance[:degraded], context: current_context&.key || "root")
        sse(:done, {})
      end
    rescue ActionController::Live::ClientDisconnected
    rescue => e
      Enliterator.logger&.error("[enliterator] conversation stream error: #{e.class}: #{e.message}")
      sse(:error, message: "conversation failed") rescue nil
    ensure
      response.stream.close
    end
```

(`method(:sse)` adapts the controller's private `sse(event, data)` into the loop's `sink.call(event, data)` — same arity.)

- [ ] **Step 4: Gate the view JS (byte-identical when off)**

In `app/views/enliterator/conversation/index.html.erb`, wrap the NEW widget/handoff JS in a server-rendered federation branch so the no-federation view file renders identically to today. At the point where the inline `<script>` handles SSE frames, add (only emitted when on):

```erb
<% if Enliterator.configuration.chat_federation %>
  <script>
    // v0.28 widget-aware handlers — appended ONLY under federation. The existing
    // handleFrame already ignores unknown events (no else), so these are additive.
    window.ENL_FEDERATION = true;
    // tool_call_result → append data.html; handoff → update the scope banner text.
    // (Implementer: extend the existing frame switch to handle
    //  'tool_call_start' | 'tool_call_result' | 'tool_call_error' | 'handoff'.)
  </script>
<% end %>
```

Then in the existing frame-handling switch, add the new branches guarded by `window.ENL_FEDERATION` so the no-federation path is untouched: `tool_call_result` appends `JSON.parse(data).html` into the transcript; `handoff` sets the scope-banner element's text to `"Desk: " + JSON.parse(data).to`; `tool_call_error` appends a small error line; `tool_call_start` optionally shows a status pill. Give the scope-banner element an `id="enl-scope-banner"` in the existing banner markup so the JS has a handle (it currently has none).

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/requests/enliterator/conversation_federation_spec.rb`
Expected: PASS (2 examples).

- [ ] **Step 6: Run the FULL suite (byte-identical floor + everything green)**

Run: `bundle exec rspec 2>&1 | tail -3`
Expected: `0 failures`, total = baseline + the new examples (~30+).

- [ ] **Step 7: Commit**

```bash
git add app/controllers/enliterator/conversation_controller.rb app/views/enliterator/conversation/index.html.erb spec/requests/enliterator/conversation_federation_spec.rb
git commit -m "v0.28: drive Chat::Loop from the authed controller, federation-gated + byte-identical"
```

---

## Task 10: Wire HSDL's federation (the live integration) + docs

Register the Frontdesk + CHDS-Theses specialist in HSDL's initializer and verify live. Then SPEC/README/About per the engine's version discipline.

**Files:**
- Modify (HSDL): `config/initializers/enliterator.rb` (register agents; set `config.chat_federation = true`)
- Modify (engine): `SPEC.md` (v0.28 section), `README.md`, `app/views/enliterator/about/index.html.erb`, `CLAUDE.md`

- [ ] **Step 1: Register the agents in HSDL**

In HSDL `config/initializers/enliterator.rb`, after the existing config, add a CHDS program-facts prompt constant (faculty-eval-informed — a small authored block, NOT free-form claims) and:

```ruby
  config.chat_federation = true
  Enliterator::Chat.register(
    name: "Frontdesk", grounding: nil,
    system_prompt: "You are the HSDL reference desk. Triage the patron's question; if it is about " \
                   "CHDS master's thesis topics or supervision, route to the CHDS Theses desk. " \
                   "Answer general/cross-collection questions directly. Cite records by title, never raw id.",
    tools: %w[collection_overview search browse_subjects subject_search record_entry connections trajectory provenance quote accuracy vocabulary],
    tier: "bedrock-haiku", routes_to: %w[CHDS\ Theses])
  Enliterator::Chat.register(
    name: "CHDS Theses", grounding: "chds-theses",
    system_prompt: CHDS_DESK_PROMPT,   # persona + authored program facts
    tools: %w[collection_overview search browse_subjects subject_search record_entry connections trajectory provenance quote accuracy vocabulary],
    tier: "bedrock-sonnet")
```

(NOTE: `bedrock-haiku`/`bedrock-sonnet` are deployment-provisioned gateway aliases; registration fail-fasts if absent. Confirm the gateway advertises them — the campaign provisioned them.)

- [ ] **Step 2: Restart + live-verify the handoff**

```bash
cd ../hsdl-ai && bin/restart web && sleep 6
```
Then in a browser at `http://localhost:3055/enliterator/chat`, ask "help me pick a thesis topic about port security" and confirm: a `handoff` updates the banner to "Desk: CHDS Theses", a `search`/`record_entry` widget renders inline with provenance, and a follow-up "how do you know that?" renders a `provenance` widget. (Plan B adds the chrome-devtools-mcp automated live check against the public URL.)

- [ ] **Step 3: SPEC/README/About**

Add the SPEC.md v0.28 section (the Reference Desk; Plan A scope = the authed agentic core; Plan B = the public desk, forthcoming). Touch README's chat description. Update the About colophon's lead line to v0.28. Update the engine `CLAUDE.md` current-state with the Chat::Agent/Loop/Widget surface and the federation gate.

- [ ] **Step 4: Commit (engine, LOCAL — push gated)**

```bash
cd /Volumes/jer4TBv3/workspaces/work/enliterator
git add SPEC.md README.md app/views/enliterator/about/index.html.erb CLAUDE.md
git commit -m "v0.28: SPEC/README/About/CLAUDE — the Reference Desk (Plan A: agentic core)"
git status -sb   # confirm clean; engine push stays gated on Jeremy's word
```

---

## Self-Review (run before execution)

**Spec coverage (design → task):** converse_with_tools → T1; widgets (8) → T2/T3/T4; agent federation + tier validation → T5; the loop's enforcement boundary (allow-list/grounding/route_to/step-cap) → T6; wall-clock + connections degraded → T7; accuracy cache → T8; transport gating + byte-identical + event vocabulary + view-flag → T9; HSDL wiring + grounding facts + docs → T10. **Deferred to Plan B (named):** the public sessionless controller, link token, rate limit + Live teardown, per-surface scrub, the web tool + leashed/labeled, the per-call public timeout, the chrome-devtools live check, Atlas warm-per-context. Ephemeral attributable-turn threads: the loop's `messages` array IS the thread within a turn; cross-turn history rides the existing client `history` param (unchanged) — persistent/collaborative threads remain horizon.

**Placeholder scan:** T9 Step 4 leaves the exact JS frame-branch wiring as prose with an explicit element id + event list (the existing 266-line view JS isn't reproduced); this is the one spot an executor extends existing code rather than writing fresh — acceptable, but the executor must read `index.html.erb` first. T7 Step 3a notes the spec should inject a `FakeClock` via `clock:` rather than mutate the module — pin that when executing.

**Type consistency:** `ToolTurn` (T1) is consumed by `Chat::Loop` (T6/T7) and the request spec (T9) — same struct, keyword init. `Chat::Widget.render(tool_name, result)` (T2-4) called by the loop (T6) — same arity. `Chat.register/for_context/frontdesk/reset!` (T5) used by the loop and specs (T6/T7/T9) — consistent. The loop's `sink.call(event, data)` matches the controller's `sse(event, data)` (T9).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-12-reference-desk-agentic-core.md`. Plan B (the public desk) follows once A lands.
