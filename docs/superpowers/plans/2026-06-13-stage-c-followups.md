# Stage C — Agent-Reasoned Follow-ups (v0.35) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mechanical 4-template follow-up scaffold with next-questions the model reasons from the answer it just gave, delivered inline (approach B) and instrumented so we can measure emission reliability, quality, and click-through.

**Architecture:** The model ends its final answer with a `%%FOLLOWUPS%%` sentinel block (≤3 questions, one per line). `Chat::Loop` injects a generic directive to produce it (federation-gated by a new `config.chat_followups`, default off), parses the tail server-side after the answer, emits a new federation-only `followups` SSE event with the clean list, and logs the outcome. The federated client renders the prose with the sentinel tail stripped (never flashing it mid-stream), renders buttons from the event, and marks follow-up-originated submits (`from_followup=1`) so the controller logs click-through. The old `FOLLOWUP_FORMS` DOM-scrape is retired; static starters remain the rule-3 fallback.

**Tech Stack:** Ruby 3.4.5 / Rails 8.1 engine, RSpec, ActionController::Live SSE, inline vanilla JS (no deps), node for JS golden tests.

**Hard rules that bite here:**
- **Rule 1 (byte-identical when off):** `config.chat_followups` defaults nil/false → engine suite byte-identical; it nests under `chat_federation`, so `chat_federation` off is unchanged. The shared `scheduleRender` and the single-shot path are NOT touched — the federated path gets its own `scheduleRenderFederated`.
- **Rule 2 (100% inline UI):** all client code inline in the ERB; no gems/CDN/assets.
- **Rule 3 (no silent failure):** no block / malformed → static starters fallback; the loop logs emitted=false too.

---

## File Structure

- **Create** `app/services/enliterator/chat/followups.rb` — pure module: `SENTINEL`, `DIRECTIVE`, `parse(text) -> [String]`. One responsibility: the protocol's text shape. No Rails deps → trivially unit-testable.
- **Modify** `lib/enliterator.rb` — add `config.chat_followups` accessor (mirror `chat_federation`).
- **Modify** `app/services/enliterator/chat/loop.rb` — inject `DIRECTIVE` into the system prompt (initial + handoff) when the flag is on; after the final answer, parse the tail → `emit(:followups, items:)` + log.
- **Modify** `app/controllers/enliterator/conversation_controller.rb` — log click-through when `params[:from_followup]` is present (gated).
- **Modify** `app/views/enliterator/conversation/index.html.erb` (inside the `<% if chat_federation %>` block only) — `proseOf` strip, `scheduleRenderFederated`, the `followups` event case + `renderFollowupButtons` + `restoreStaticStarters`, the `from_followup` submit marker; retire `FOLLOWUP_FORMS`/`consultedLabels`/`refreshFollowups`.
- **Create** `spec/services/enliterator/chat/followups_spec.rb` — parser cases.
- **Modify** `spec/services/enliterator/chat/loop_spec.rb` — directive/event/flag-off cases.
- **Modify** `spec/requests/enliterator/conversation_federation_spec.rb` — event gating + off-view cleanliness.
- **Create** `spec/javascript/followups.test.js` — `proseOf` strip + partial-suffix guard.

---

### Task 1: `Chat::Followups` pure parser + protocol constants

**Files:**
- Create: `app/services/enliterator/chat/followups.rb`
- Test: `spec/services/enliterator/chat/followups_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/services/enliterator/chat/followups_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Followups do
  def tail(*lines) = "An answer here.\n\n#{described_class::SENTINEL}\n#{lines.join("\n")}"

  it "parses up to three clean questions after the sentinel" do
    qs = described_class.parse(tail("What changed?", "Who cited it?", "How does it connect?"))
    expect(qs).to eq([ "What changed?", "Who cited it?", "How does it connect?" ])
  end

  it "returns [] when the sentinel is absent (model omitted the block)" do
    expect(described_class.parse("Just an answer, no block.")).to eq([])
  end

  it "caps at three even if the model emits more" do
    qs = described_class.parse(tail("a?", "b?", "c?", "d?", "e?"))
    expect(qs).to eq([ "a?", "b?", "c?" ])
  end

  it "strips bullet/number prefixes and drops blank lines" do
    qs = described_class.parse(tail("- First?", "", "2. Second?", "  * Third?  "))
    expect(qs).to eq([ "First?", "Second?", "Third?" ])
  end

  it "returns [] when the sentinel is present but nothing follows" do
    expect(described_class.parse("Answer.\n\n#{described_class::SENTINEL}\n")).to eq([])
  end

  it "uses the suffix after the FIRST sentinel occurrence" do
    text = "Answer.\n\n#{described_class::SENTINEL}\nOnly?\n#{described_class::SENTINEL}\nNope?"
    expect(described_class.parse(text)).to eq([ "Only?" ])
  end

  it "tolerates CRLF and trailing whitespace" do
    text = "Answer.\r\n\r\n#{described_class::SENTINEL}\r\nQ one?\r\nQ two?\r\n"
    expect(described_class.parse(text)).to eq([ "Q one?", "Q two?" ])
  end

  it "exposes a DIRECTIVE string that names the sentinel literally" do
    expect(described_class::DIRECTIVE).to include(described_class::SENTINEL)
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `bundle exec rspec spec/services/enliterator/chat/followups_spec.rb`
Expected: FAIL (uninitialized constant `Enliterator::Chat::Followups`).

- [ ] **Step 3: Implement the module**

```ruby
# app/services/enliterator/chat/followups.rb
# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.35 Stage C: the inline follow-up protocol. The model ends its final
    # answer with SENTINEL on its own line, then up to three next-questions (one
    # per line). This module is the single source of truth for that shape: the
    # DIRECTIVE the Loop injects, and the parser the Loop runs on the answer.
    # Pure — no Rails, no I/O — so the contract is unit-testable in isolation.
    module Followups
      SENTINEL = "%%FOLLOWUPS%%"
      MAX = 3

      DIRECTIVE = <<~TXT.strip
        When you have completely finished your answer, append a final block so the
        reader can navigate onward. On its own line, write exactly:

        #{SENTINEL}

        Then write up to three short questions — one per line, no numbering or
        bullets — that the reader could naturally ask NEXT given the answer you just
        gave. Make them specific to this answer, not generic. Put nothing after the
        last question. If no genuinely useful follow-up exists, omit the block entirely.
      TXT

      # Parse the questions out of an answer's trailing sentinel block. Returns
      # [] when the block is absent or empty (the caller falls back to static
      # starters — rule 3). Splits on the FIRST sentinel occurrence, strips
      # bullet/number prefixes, drops blanks, caps at MAX.
      def self.parse(text)
        s = text.to_s
        i = s.index(SENTINEL)
        return [] if i.nil?
        s[(i + SENTINEL.length)..]
          .to_s
          .split(/\r?\n/)
          .map { |line| line.sub(/\A\s*(?:[-*]|\d+[.)])\s*/, "").strip }
          .reject(&:empty?)
          .first(MAX)
      end
    end
  end
end
```

- [ ] **Step 4: Run it green**

Run: `bundle exec rspec spec/services/enliterator/chat/followups_spec.rb`
Expected: PASS (8 examples).

- [ ] **Step 5: Commit**

```bash
git add app/services/enliterator/chat/followups.rb spec/services/enliterator/chat/followups_spec.rb
git commit -m "v0.35: Chat::Followups — the inline follow-up protocol (sentinel, directive, parser)"
```

---

### Task 2: `config.chat_followups` flag + Loop directive injection + `:followups` emit + log

**Files:**
- Modify: `lib/enliterator.rb` (add accessor near `chat_federation` at :164, init at :207)
- Modify: `app/services/enliterator/chat/loop.rb`
- Test: `spec/services/enliterator/chat/loop_spec.rb` (extend)

**Context:** `Loop#run` (`loop.rb:34`) builds `messages[0]` as the system message from `@agent.system_prompt`; on handoff, `handle_calls` resets `messages[0]` (`loop.rb:121`). The final-answer branch is `loop.rb:76`:
```ruby
if turn.tool_calls.empty?
  emit(:token, t: turn.text.to_s) unless streamed
  break
end
```
The sink already JSON-serializes arbitrary `event, hash` payloads (the v0.28 `tool_call_start`/`handoff` events prove it), so `emit(:followups, items: [...])` needs no controller change.

- [ ] **Step 1: Add the config flag** (`lib/enliterator.rb`)

After the `chat_federation` accessor block (around :164), add:
```ruby
    # v0.35 Stage C. nil/false ⇒ no follow-up directive is injected and no
    # :followups event is emitted (byte-identical to v0.34). true ⇒ the Loop asks
    # the model for an inline %%FOLLOWUPS%% block, parses it, emits :followups, and
    # logs the outcome. Nests under chat_federation (the Loop only runs when that is on).
    attr_accessor :chat_followups
```
In `initialize` (after `@chat_federation = nil` at :207):
```ruby
      @chat_followups = nil
```

- [ ] **Step 2: Write the failing loop specs** (append to `spec/services/enliterator/chat/loop_spec.rb`)

Use the file's existing fake-LLM/sink conventions. Add a context:
```ruby
  describe "v0.35 follow-ups (config.chat_followups)" do
    # A fake whose single content turn carries a sentinel tail.
    let(:answer_with_tail) do
      "Here is the answer.\n\n#{Enliterator::Chat::Followups::SENTINEL}\nWhat changed?\nWho cited it?"
    end

    def fake_llm(text)
      Class.new do
        define_method(:converse_with_tools) do |messages:, tools:, stream: false, &blk|
          @seen = messages
          Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
            text: text, tool_calls: [], assistant_message: nil, tokens: {})
        end
        attr_reader :seen
      end.new
    end

    let(:agent) do
      Enliterator::Chat::Agent.new(name: "Desk", grounding: nil, system_prompt: "You are the Desk.",
                                   tool_names: %w[search], tier: "cheap", routes_to: [])
    end

    it "with the flag ON, injects the directive into the system prompt and emits :followups" do
      Enliterator.configuration.chat_followups = true
      llm = fake_llm(answer_with_tail)
      events = []
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(e, d) { events << [ e, d ] }).run("hi")
      expect(llm.seen.first["content"]).to include(Enliterator::Chat::Followups::SENTINEL)
      fu = events.find { |e, _| e == :followups }
      expect(fu).not_to be_nil
      expect(fu.last[:items]).to eq([ "What changed?", "Who cited it?" ])
    ensure
      Enliterator.configuration.chat_followups = nil
    end

    it "with the flag OFF (default), injects NO directive and emits NO :followups (byte-identical)" do
      llm = fake_llm(answer_with_tail)
      events = []
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(e, d) { events << [ e, d ] }).run("hi")
      expect(llm.seen.first["content"]).not_to include(Enliterator::Chat::Followups::SENTINEL)
      expect(events.map(&:first)).not_to include(:followups)
    end

    it "with the flag ON but the model omits the block, emits NO :followups" do
      Enliterator.configuration.chat_followups = true
      llm = fake_llm("A plain answer with no block.")
      events = []
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(e, d) { events << [ e, d ] }).run("hi")
      expect(events.map(&:first)).not_to include(:followups)
    ensure
      Enliterator.configuration.chat_followups = nil
    end
  end
```
> NOTE for implementer: match the REAL `Chat::Agent.new` keyword signature and the REAL `ToolTurn` constructor in this codebase. Read `app/services/enliterator/chat/agent.rb` and `adapters/llm/gateway.rb` first and adjust the fakes/constructors above to match exactly (arg names may differ — e.g. `tools:` vs `tool_names:`). Do not invent a signature.

- [ ] **Step 3: Run, expect failure**

Run: `bundle exec rspec spec/services/enliterator/chat/loop_spec.rb`
Expected: FAIL (no directive injected; no `:followups`).

- [ ] **Step 4: Implement in `loop.rb`**

Add a helper and use it where the system message is set:
```ruby
      # System content for the active agent. v0.35: when chat_followups is on,
      # append the generic follow-up directive so the answering desk ends with the
      # %%FOLLOWUPS%% block. Off ⇒ the bare persona (byte-identical to v0.34).
      def system_content
        base = @agent.system_prompt
        return base unless Enliterator.configuration.chat_followups
        "#{base}\n\n#{Enliterator::Chat::Followups::DIRECTIVE}"
      end
```
In `run` (replace the system entry at :35):
```ruby
        messages = [ { "role" => "system", "content" => system_content },
                     { "role" => "user", "content" => question.to_s } ]
```
In `handle_calls` route_to branch (replace :121):
```ruby
              messages[0] = { "role" => "system", "content" => system_content }
```
In the final-answer branch (:76–79), after the existing token emit:
```ruby
          if turn.tool_calls.empty?
            emit(:token, t: turn.text.to_s) unless streamed
            emit_followups(turn.text) if Enliterator.configuration.chat_followups
            break
          end
```
Add the private method:
```ruby
      # v0.35: parse the answer's trailing %%FOLLOWUPS%% block and surface the
      # questions as a structured event (the client renders them as buttons). The
      # raw tail still rides in the :token stream — the client strips it for display;
      # this event is the authoritative button source. Always log the outcome so the
      # experiment can measure emission reliability (rule 3: emitted=false is logged too).
      def emit_followups(text)
        items = Enliterator::Chat::Followups.parse(text)
        emit(:followups, items: items) if items.any?
        Enliterator.logger&.info(
          "[enliterator] followups agent=#{@agent.name} emitted=#{items.any?} " \
          "count=#{items.size} items=#{items.inspect}")
      end
```

- [ ] **Step 5: Run green + full suite**

Run: `bundle exec rspec spec/services/enliterator/chat/loop_spec.rb && bundle exec rspec`
Expected: PASS, full suite green (existing federation/loop specs unchanged because the flag defaults off).

- [ ] **Step 6: Commit**

```bash
git add lib/enliterator.rb app/services/enliterator/chat/loop.rb spec/services/enliterator/chat/loop_spec.rb
git commit -m "v0.35: Loop injects the follow-up directive + emits :followups (config.chat_followups, default off)"
```

---

### Task 3: Controller click-through logging

**Files:**
- Modify: `app/controllers/enliterator/conversation_controller.rb`
- Test: `spec/requests/enliterator/conversation_federation_spec.rb` (extend)

**Context:** Read the `#stream` action first. SSE header assignments must stay first (do not insert before them). Add the log AFTER headers are set, gated by `chat_followups`, reading `params[:from_followup]`.

- [ ] **Step 1: Write the failing request spec** (add inside the existing federation describe block)

```ruby
  it "logs a follow-up click-through when from_followup is present (flag on)" do
    Enliterator.configuration.chat_followups = true
    Enliterator.configuration.chat_federation = true
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    allow(Enliterator).to receive(:llm).and_return(
      double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
        text: "ok", tool_calls: [], assistant_message: nil, tokens: {})))
    expect(Enliterator.logger).to receive(:info).with(/followup_click/).at_least(:once)
    allow(Enliterator.logger).to receive(:info) # allow the loop's other info logs
    post "/enliterator/chat/stream", params: { question: "hi", from_followup: "1" }
  ensure
    Enliterator.configuration.chat_followups = nil
  end
```
> NOTE: order the `expect`/`allow` so the matched `info` call is still observed — if the existing helper conventions differ, prefer a spy: `allow(Enliterator.logger).to receive(:info)` then `expect(Enliterator.logger).to have_received(:info).with(/followup_click/)` after the post.

- [ ] **Step 2: Run, expect failure** — Run: `bundle exec rspec spec/requests/enliterator/conversation_federation_spec.rb`

- [ ] **Step 3: Implement** — in `#stream`, after the SSE headers, before driving the loop:
```ruby
    if Enliterator.configuration.chat_followups && params[:from_followup].present?
      Enliterator.logger&.info("[enliterator] followup_click q=#{params[:question].to_s[0, 80].inspect}")
    end
```

- [ ] **Step 4: Run green** — Run: `bundle exec rspec spec/requests/enliterator/conversation_federation_spec.rb`

- [ ] **Step 5: Commit**
```bash
git add app/controllers/enliterator/conversation_controller.rb spec/requests/enliterator/conversation_federation_spec.rb
git commit -m "v0.35: controller logs follow-up click-through (gated, truncated query)"
```

---

### Task 4: Client — `proseOf` strip (the JS golden, TDD first)

**Files:**
- Create: `spec/javascript/followups.test.js`
- Modify: `app/views/enliterator/conversation/index.html.erb` (add `proseOf` inside the federation block)

**Context:** The lift harness pattern is in `spec/javascript/cite_logic.test.js` (read it). `proseOf` must live inside the `<% if chat_federation %>` block so it is withheld from the OFF view. It is pure string work (no DOM) — easy to lift.

- [ ] **Step 1: Write the failing JS test**

```js
// spec/javascript/followups.test.js
"use strict";
// Lifts the REAL proseOf from the federated view block and proves the load-bearing
// streaming-safety property: the %%FOLLOWUPS%% sentinel (and any partial prefix of
// it arriving mid-stream) is NEVER part of the rendered prose.
const fs = require("fs");
const path = require("path");
const VIEW = path.join(__dirname, "..", "..", "app", "views", "enliterator", "conversation", "index.html.erb");
const src = fs.readFileSync(VIEW, "utf8");
const scriptSrc = src.slice(src.indexOf("<script>") + 8, src.lastIndexOf("</script>"));
function lift(name) {
  const sig = "function " + name + "(";
  const start = scriptSrc.indexOf(sig);
  if (start === -1) throw new Error("missing " + sig);
  const bs = scriptSrc.indexOf("{", start);
  let d = 0;
  for (let i = bs; i < scriptSrc.length; i++) {
    if (scriptSrc[i] === "{") d++;
    else if (scriptSrc[i] === "}") { d--; if (d === 0) return scriptSrc.slice(start, i + 1); }
  }
  throw new Error("unbalanced " + name);
}
const SENTINEL = "%%FOLLOWUPS%%";
const api = new Function(lift("proseOf") + "\nreturn { proseOf: proseOf };")();
let pass = 0, fail = 0;
function ok(c, m) { if (c) pass++; else { fail++; console.error("  ✗ " + m); } }

ok(api.proseOf("Answer here.") === "Answer here.", "no sentinel → unchanged");
ok(api.proseOf("Answer.\n\n" + SENTINEL + "\nQ1?\nQ2?") === "Answer.\n\n",
   "full sentinel → prose is everything before it");
// Partial sentinel arriving mid-stream must be held back (never flashed).
ok(api.proseOf("Answer.\n\n%%FOLL").indexOf("%%FOLL") === -1, "partial sentinel prefix is withheld");
ok(api.proseOf("Answer.\n\n%%FOLL") === "Answer.\n\n", "withholding leaves clean prose");
ok(api.proseOf("It rose 5%").indexOf("5%") !== -1, "a lone % that is a valid 1-char prefix is still withheld only as that char");
// A real trailing '%' is a 1-char prefix of the sentinel; it may lag one tick but
// must never corrupt — assert the non-% text is intact.
ok(api.proseOf("done").indexOf("done") === 0, "ordinary text passes through");

console.log((fail === 0 ? "✓ ALL " : "✗ ") + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
```
> NOTE: the `5%` case documents that a trailing `%` is treated as a partial-sentinel prefix and held back one render tick (revealed when the next token arrives or on the final flush, which passes the COMPLETE text). If the implementer finds this assertion too strict for the chosen guard, adjust the assertion to match the implemented (documented) behavior — the invariant that MUST hold is "the literal `%%FOLLOWUPS%%` and partial `%%FOLLOWUPS...` prefixes never appear in the returned prose."

- [ ] **Step 2: Run, expect failure** — Run: `node spec/javascript/followups.test.js` (fails: `proseOf` not found).

- [ ] **Step 3: Implement `proseOf`** inside the federation block (near `scheduleRender`'s federated sibling, Task 5). Add a `SENTINEL` const too:
```js
  var FOLLOWUP_SENTINEL = "%%FOLLOWUPS%%";
  // Return the displayable prose: everything before the follow-up sentinel. During
  // streaming the sentinel arrives token-by-token, so also withhold any trailing
  // run that is a prefix of the sentinel — otherwise "%%FOLL" would flash before the
  // rest arrives. The final flush passes the COMPLETE text, so nothing is lost.
  function proseOf(text) {
    var i = text.indexOf(FOLLOWUP_SENTINEL);
    if (i !== -1) return text.slice(0, i);
    var max = Math.min(text.length, FOLLOWUP_SENTINEL.length - 1);
    for (var k = max; k > 0; k--) {
      if (text.slice(text.length - k) === FOLLOWUP_SENTINEL.slice(0, k)) return text.slice(0, text.length - k);
    }
    return text;
  }
```
> The test lifts `proseOf` standalone (no closure deps), so `FOLLOWUP_SENTINEL` must be referenced by the literal inside `proseOf` OR the test must inject it. Simplest: keep the literal inside `proseOf` (define `var S = "%%FOLLOWUPS%%";` as the FIRST line of the function body) so the lift is self-contained. Implementer: ensure the lifted function has no free variables.

- [ ] **Step 4: Run green** — Run: `node spec/javascript/followups.test.js`

- [ ] **Step 5: Commit**
```bash
git add spec/javascript/followups.test.js app/views/enliterator/conversation/index.html.erb
git commit -m "v0.35: client proseOf — strip the follow-up sentinel from streamed prose (golden-guarded)"
```

---

### Task 5: Client — federated render strip, `followups` event → buttons, `from_followup` marker; retire the scaffold

**Files:**
- Modify: `app/views/enliterator/conversation/index.html.erb` (federation block only)

**Context (exact current code):**
- `handleFrameFederated` token case (:769–772): `state.text += payload.t || ""; scheduleRender(els, state);`
- `finishTurnFederated` flush (:864): `els.md.innerHTML = mdToHtml(state.text);`; history push (:888): `content: state.text`; follow-up call (:893): `refreshFollowups(els);`
- `submitQuestionFederated` FormData (:934–936).
- The dynamic-followups block (:989–1063): `promptsEl`, `staticPromptsHTML`, `wirePrompt`, `consultedLabels`, `FOLLOWUP_FORMS`, `refreshFollowups`.

- [ ] **Step 1: Add `scheduleRenderFederated`** (next to `proseOf`; mirrors the shared `scheduleRender` but renders stripped prose). Leaves `scheduleRender` untouched (single-shot keeps it byte-identical):
```js
  // Federated render: identical 70ms debounce to scheduleRender, but renders the
  // PROSE (sentinel tail stripped) so the %%FOLLOWUPS%% block never shows. The
  // shared scheduleRender is left untouched for the single-shot path (rule 1).
  function scheduleRenderFederated(els, state) {
    if (state.timer) return;
    state.timer = setTimeout(function () {
      state.timer = null;
      els.md.innerHTML = mdToHtml(proseOf(state.text));
      followStream();
    }, 70);
  }
```

- [ ] **Step 2: Point the federated token handler at it** (:771):
```js
    if (ev === "token") {
      ensureAnswer(els);
      state.text += payload.t || ""; scheduleRenderFederated(els, state);
    }
```

- [ ] **Step 3: Add the `followups` event case** (in `handleFrameFederated`, before the `// ev === "done"` comment at :853):
```js
    else if (ev === "followups") {
      renderFollowupButtons(payload.items || []);
      els.gotFollowups = true;
    }
```

- [ ] **Step 4: Fix `finishTurnFederated`** — render stripped prose, push clean history, and fall back to static starters only when no event arrived:
  - :864 → `els.md.innerHTML = mdToHtml(proseOf(state.text));`
  - :888 → `history.push({ role: "assistant", content: proseOf(state.text) });`
  - :893 → replace `refreshFollowups(els);` with:
```js
    // v0.35: buttons came from the :followups event during the stream. If none
    // arrived (model omitted the block, or the flag is off), restore the static
    // starters so the prompt bar is never blank (rule 3).
    if (!els.gotFollowups) restoreStaticStarters();
```

- [ ] **Step 5: Add the `from_followup` marker** in `submitQuestionFederated` FormData (:936, after the history append):
```js
    if (fromFollowup) { body.append("from_followup", "1"); fromFollowup = false; }
```

- [ ] **Step 6: Replace the dynamic-followups block (:989–1063)** — retire `consultedLabels`, `FOLLOWUP_FORMS`, `refreshFollowups`; keep `promptsEl`/`staticPromptsHTML`/`wirePrompt`; add the module flag, `restoreStaticStarters`, and `renderFollowupButtons`:
```js
  // ── Follow-ups (v0.35: rendered from the server's :followups event) ─────────
  var promptsEl = document.getElementById("prompts");
  var staticPromptsHTML = promptsEl ? promptsEl.innerHTML : null;
  var fromFollowup = false; // set by a follow-up button click; read once in submitQuestionFederated

  function wirePrompt(b) {
    b.addEventListener("click", function () {
      if (send.disabled) return;
      input.value = b.textContent.trim(); autosize();
      submitQuestion(input.value);
    });
  }

  // Restore the original starter buttons (the rule-3 fallback when a turn produced
  // no follow-ups). Re-wires because innerHTML restore drops listeners.
  function restoreStaticStarters() {
    if (!promptsEl || staticPromptsHTML === null) return;
    if (promptsEl.innerHTML === staticPromptsHTML) return;
    promptsEl.innerHTML = staticPromptsHTML;
    promptsEl.querySelectorAll("button.prompt").forEach(wirePrompt);
  }

  // Render the server-reasoned next-questions as buttons. A click flags the next
  // submit as follow-up-originated (for click-through instrumentation), populates
  // the composer, and sends. Empty list → keep starters (rule 3).
  function renderFollowupButtons(items) {
    if (!promptsEl || !items || !items.length) { restoreStaticStarters(); return; }
    promptsEl.innerHTML = "";
    var label = document.createElement("span");
    label.className = "label"; label.textContent = "Follow up:";
    promptsEl.appendChild(label);
    items.forEach(function (q) {
      var btn = document.createElement("button");
      btn.type = "button"; btn.className = "prompt"; btn.textContent = q;
      btn.addEventListener("click", function () {
        if (send.disabled) return;
        fromFollowup = true;
        input.value = q; autosize();
        submitQuestion(input.value);
      });
      promptsEl.appendChild(btn);
    });
    followStream();
  }
```
> `els.gotFollowups` is a fresh per-turn flag — initialize it in the `els` object literal in `submitQuestionFederated` (:912–918) as `gotFollowups: false` alongside `sourceCount: 0`.

- [ ] **Step 7: Verify script syntax + JS goldens**

Run:
```bash
node -e 'const fs=require("fs");let s=fs.readFileSync("app/views/enliterator/conversation/index.html.erb","utf8");let x=s.slice(s.indexOf("<script>")+8,s.lastIndexOf("</script>")).replace(/<%[=-]?[\s\S]*?%>/g,"0");fs.writeFileSync("/tmp/enl.js",x);' && node --check /tmp/enl.js && echo OK
for f in spec/javascript/*.test.js; do node "$f" || exit 1; done
```
Expected: `OK` + all JS golden suites pass.

- [ ] **Step 8: Commit**
```bash
git add app/views/enliterator/conversation/index.html.erb
git commit -m "v0.35: federated client renders server-reasoned follow-ups; retire the DOM-scrape scaffold"
```

---

### Task 6: Federation regression spec — event gating + off-view cleanliness

**Files:**
- Modify: `spec/requests/enliterator/conversation_federation_spec.rb`

- [ ] **Step 1: Add gating examples**

```ruby
  it "with federation ON but chat_followups OFF, emits NO :followups event" do
    Enliterator.configuration.chat_federation = true
    Enliterator.configuration.chat_followups = nil
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    allow(Enliterator).to receive(:llm).and_return(
      double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
        text: "ans\n\n#{Enliterator::Chat::Followups::SENTINEL}\nQ?", tool_calls: [],
        assistant_message: nil, tokens: {})))
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response.body).not_to include("event: followups")
  end

  it "with chat_followups ON, emits a :followups event carrying the parsed questions" do
    Enliterator.configuration.chat_federation = true
    Enliterator.configuration.chat_followups = true
    Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                               tools: %w[search], tier: "cheap")
    allow(Enliterator).to receive(:llm).and_return(
      double(converse_with_tools: Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
        text: "ans\n\n#{Enliterator::Chat::Followups::SENTINEL}\nWhat next?", tool_calls: [],
        assistant_message: nil, tokens: {})))
    post "/enliterator/chat/stream", params: { question: "hi" }
    expect(response.body).to include("event: followups")
    expect(response.body).to include("What next?")
  ensure
    Enliterator.configuration.chat_followups = nil
  end
```
> Add `Enliterator.configuration.chat_followups = nil` to the existing `after` block so no example leaks the flag.

- [ ] **Step 2: Confirm the off-view spec still passes unchanged** — the OFF chat page (`chat_federation` nil) emits none of the federation JS; `proseOf`/`scheduleRenderFederated`/`renderFollowupButtons` all live inside the gate, so the off view is unaffected. The existing `body_without_layout_css` assertions must stay green. If desired, add `renderFollowupButtons` and `proseOf` to a comment noting they're gate-only (do NOT add them to `FEDERATED_JS` unless you also confirm they never appear off-view — they shouldn't).

- [ ] **Step 3: Run the full suite + all JS goldens**
```bash
bundle exec rspec && for f in spec/javascript/*.test.js; do node "$f" || exit 1; done
```
Expected: green; example count = prior + new.

- [ ] **Step 4: Commit**
```bash
git add spec/requests/enliterator/conversation_federation_spec.rb
git commit -m "v0.35: pin :followups event gating (off → absent, on → parsed questions)"
```

---

## Verification (final, before HSDL live)

- `bundle exec rspec` green from engine root (642 + new).
- `node spec/javascript/*.test.js` all green (cite_logic, error_card, md_golden, followups).
- `node --check` on the stripped script passes.
- Off-view byte-identity intact (conversation_federation_spec OFF examples green).

## HSDL live-verify (Jeremy-gated — restart + Bedrock cost)

1. In HSDL `config/initializers/enliterator.rb` (uncommitted, gated): add `c.chat_followups = true`.
2. `cd ../hsdl-ai && bin/restart web` (engine Ruby changed).
3. Ask a search-style question; confirm: the answer streams with NO `%%FOLLOWUPS%%` visible; 3 contextual follow-up buttons appear (not the old "Tell me more about X DocMetum" template); clicking one re-asks and the next turn's follow-ups differ.
4. Confirm a turn that warrants no follow-ups falls back to static starters.
5. `grep "followups" ~hsdl development.log` (or the app log) shows `emitted=true count=N items=[...]` per turn and `followup_click` on clicks — the experiment's readout.

## Out of scope (named)
- Approach A (separate second-pass call) — deferred unless the logged data motivates it.
- Typed deeper/lateral/wider moves; a durable follow-up-events table (logs suffice for v1; graduate to a service+rake+MCP per the compounding-tooling directive if the query recurs).
- Server-side withholding of the tail tokens (client display-strip is lower-risk).
- SPEC.md/About sections (this ships commit-only, consistent with v0.31–v0.34; the doc-debt catch-up is a separate flagged pass).
