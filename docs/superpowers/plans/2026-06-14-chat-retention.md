# Chat Retention (v0.39) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Persist `/enliterator/chat` federation conversations (gated), and re-stream any saved conversation through the live client for repeatable demos. `Chat::Turn` is built tendable-ready for the v2 conversation-tending loop.

**Architecture:** The Loop's event array is the artifact. Capture = teeing the controller sink; replay = re-emitting the stored events over the same SSE writer (the federated client can't tell replay from live). Store: `Chat::Conversation` + `Chat::Turn` (events jsonb + denormalized answer/desk/persona/timing). `config.chat_retention` gates everything (default off → byte-identical to v0.38).

**Design doc:** `docs/superpowers/specs/2026-06-14-chat-retention-design.md`.

**Hard rules:** (1) byte-identical when `chat_retention` off; (2) 100% inline UI; (3) no silent failure (a malformed event array still records the turn; recorder never raises into the request); (7) reversible migrations applied to `spec/dummy` + HSDL.

---

## Phase 1a — store + capture

### Task 1: migrations + models + `config.chat_retention`

**Files:** two migrations; `app/models/enliterator/chat/conversation.rb`, `app/models/enliterator/chat/turn.rb`; `lib/enliterator.rb`; model specs.

- [ ] **Step 1: migrations** (timestamps must sort after `20260614120000`)
```ruby
# db/migrate/20260614130000_create_enliterator_chat_conversations.rb
class CreateEnliteratorChatConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_chat_conversations do |t|
      t.string :token,   null: false   # client-generated uuid; the grouping key
      t.string :context                 # grounding key or nil (whole collection)
      t.string :label                   # nullable — name a demo exemplar
      t.string :source, null: false, default: "live"  # live | eval
      t.timestamps
    end
    add_index :enliterator_chat_conversations, :token, unique: true
  end
end
```
```ruby
# db/migrate/20260614130100_create_enliterator_chat_turns.rb
class CreateEnliteratorChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_chat_turns do |t|
      t.references :conversation, null: false, foreign_key: { to_table: :enliterator_chat_conversations }
      t.integer :ordinal,   null: false
      t.text    :question,  null: false
      t.jsonb   :events,    null: false, default: []   # the full ordered event stream
      t.text    :answer                                  # denormalized prose (sentinel stripped)
      t.string  :desk_name                               # the desk that composed
      t.bigint  :persona_id                              # nullable → enliterator_chat_personas version
      t.integer :elapsed_ms
      t.boolean :budget_hit, null: false, default: false
      t.timestamps
    end
    add_index :enliterator_chat_turns, [ :conversation_id, :ordinal ], unique: true
    add_index :enliterator_chat_turns, :persona_id
  end
end
```

- [ ] **Step 2: migrate the dummy** — `cd spec/dummy && bin/rails db:migrate && cd ../..`

- [ ] **Step 3: config flag** (`lib/enliterator.rb`, after `chat_persona_editing`/`chat_editor`)
```ruby
    # v0.39: gates chat retention. nil/false ⇒ no capture, replay/browse 404,
    # no nav link (byte-identical to v0.38, stateless desk). true ⇒ federation
    # turns persist (the dev/demo backend) and can be re-streamed.
    attr_accessor :chat_retention
```
plus `@chat_retention = nil` in `initialize`.

- [ ] **Step 4: models + specs** (TDD — write `spec/models/enliterator/chat/conversation_spec.rb` + `turn_spec.rb` first, red, then implement)
```ruby
# app/models/enliterator/chat/conversation.rb
module Enliterator
  module Chat
    # v0.39: a retained chat session (the dev/demo backend's conversations).
    class Conversation < Enliterator::ApplicationRecord
      self.table_name = "enliterator_chat_conversations"
      has_many :turns, -> { order(:ordinal) }, class_name: "Enliterator::Chat::Turn",
               foreign_key: :conversation_id, dependent: :destroy, inverse_of: :conversation
      validates :token, presence: true, uniqueness: true
      SOURCES = %w[live eval].freeze
    end
  end
end
```
```ruby
# app/models/enliterator/chat/turn.rb
module Enliterator
  module Chat
    # v0.39: one retained turn. `events` (jsonb) is the full ordered Loop event
    # stream — the artifact: live transport, replay source, and v2 tending input.
    # Tendable-ready (question + events + answer carry enough to grow conversation
    # -quality facets later — the v0.25 Part pattern).
    class Turn < Enliterator::ApplicationRecord
      self.table_name = "enliterator_chat_turns"
      belongs_to :conversation, class_name: "Enliterator::Chat::Conversation", inverse_of: :turns
      belongs_to :persona, class_name: "Enliterator::Chat::Persona", optional: true
      validates :question, presence: true
    end
  end
end
```
Specs: a Conversation has ordered turns; `dependent: :destroy`; Turn belongs to conversation + optional persona; events round-trips as an array of hashes.

- [ ] **Step 5: full suite green** (`bundle exec rspec`) — additive tables/flag, byte-identical.
- [ ] **Step 6: commit** — `git add` the migrations, models, `lib/enliterator.rb`, `spec/dummy/db/schema.rb`, specs; `git commit -m "v0.39: Chat::Conversation + Chat::Turn store + config.chat_retention"`.

---

### Task 2: `Chat::Recorder`

**Files:** `app/services/enliterator/chat/recorder.rb` + `spec/services/enliterator/chat/recorder_spec.rb`.

- [ ] **Step 1: failing spec** — given an events array (tokens incl. a `%%FOLLOWUPS%%` tail, a handoff, a followups event), `Recorder.record` creates a Turn with: answer = prose (sentinel stripped), desk_name = last handoff's `to`, persona_id resolved from `Persona.history(desk_name).first`, ordinal incrementing per conversation, budget_hit detected from a "step budget" answer. A malformed events entry doesn't raise (records question + raw events).

- [ ] **Step 2: implement**
```ruby
# app/services/enliterator/chat/recorder.rb
# frozen_string_literal: true
module Enliterator
  module Chat
    # v0.39: persist one captured turn. Derives the denormalized fields from the
    # event stream; never raises into the request (rule 3 — a bad event array still
    # records the question + raw events).
    module Recorder
      def self.record(conversation:, question:, events:, initial_desk: nil, elapsed_ms: nil)
        ev   = Array(events)
        answer = prose_of(ev)
        desk = last_handoff(ev) || initial_desk
        Enliterator::Chat::Turn.create!(
          conversation: conversation,
          ordinal:    (conversation.turns.maximum(:ordinal) || 0) + 1,
          question:   question.to_s,
          events:     ev,
          answer:     answer,
          desk_name:  desk,
          persona_id: desk && Enliterator::Chat::Persona.history(desk).first&.id,
          elapsed_ms: elapsed_ms,
          budget_hit: answer.to_s.match?(/step budget|time budget/))
      rescue StandardError => e
        Enliterator.logger&.warn("[enliterator] chat recorder failed: #{e.class}: #{e.message}")
        nil
      end

      def self.prose_of(ev)
        text = ev.select { |e| key(e, "event") == "token" }.map { |e| dig(e, "data", "t") }.join
        text.split(Enliterator::Chat::Followups::SENTINEL).first.to_s.strip
      end

      def self.last_handoff(ev)
        ev.select { |e| key(e, "event") == "handoff" }.map { |e| dig(e, "data", "to") }.compact.last
      end

      # events come from the controller as {"event"=>, "data"=>} (string keys, jsonb)
      # or from specs as symbol keys — tolerate both.
      def self.key(e, k)  = (e[k] || e[k.to_sym]).to_s
      def self.dig(e, *ks)
        ks.reduce(e) { |acc, k| acc.is_a?(Hash) ? (acc[k] || acc[k.to_s] || acc[k.to_sym]) : nil }
      end
    end
  end
end
```
> Implementer: align the event-hash shape between what the controller captures and what `Recorder` reads. The controller will capture `{"event" => ev.to_s, "data" => data}`; `data` itself has symbol keys at capture time but is round-tripped through jsonb (→ string keys) only when re-read from the DB. For the SAME-request record call the data still has symbol keys. Make `dig` tolerant of both (as above) and TEST both shapes.

- [ ] **Step 3: green; commit** — `git commit -m "v0.39: Chat::Recorder — persist a captured turn (derives answer/desk/persona, never raises)"`.

---

### Task 3: capture wiring (controller + Eval) + client conversation_token

**Files:** `app/controllers/enliterator/conversation_controller.rb`, `app/services/enliterator/chat/eval.rb`, `app/views/enliterator/conversation/index.html.erb`, `spec/requests/enliterator/conversation_federation_spec.rb`.

- [ ] **Step 1: controller tee** — in `#stream`, the federation branch: when `chat_retention` on, tee the sink and record after `run`. Sketch:
```ruby
      if Enliterator.configuration.chat_federation
        agent = Enliterator::Chat.for_context(current_context&.key)
        captured = [] if Enliterator.configuration.chat_retention
        sink = if captured
          ->(ev, data) { captured << { "event" => ev.to_s, "data" => data }; sse(ev, data) }
        else
          method(:sse)
        end
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Enliterator::Chat::Loop.new(agent: agent, sink: sink,
                                    error_detail: Enliterator.configuration.error_detail?).run(params[:question].to_s)
        if captured
          conv = Enliterator::Chat::Conversation.find_or_create_by(token: params[:conversation_token].presence || SecureRandom.uuid) do |c|
            c.context = current_context&.key
            c.source  = "live"
          end
          Enliterator::Chat::Recorder.record(
            conversation: conv, question: params[:question].to_s, events: captured,
            initial_desk: agent.name,
            elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
        end
      else
        # single-shot path — UNCHANGED
      end
```
Retention off ⇒ `captured` is nil ⇒ sink is `method(:sse)` ⇒ byte-identical. The single-shot branch is untouched.

- [ ] **Step 2: Eval records too** — `Chat::Eval.ask` gets a `record: Enliterator.configuration.chat_retention` default param; when true, find-or-create a `source: "eval"` Conversation (token `SecureRandom.uuid`) and `Recorder.record` after the run. Keep `Eval.ask`'s Result return unchanged.

- [ ] **Step 3: client `conversation_token`** — in `index.html.erb` (federation block), generate a per-page-load token and post it each turn:
```js
var conversationToken = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now()) + Math.random();
```
and in `submitQuestionFederated`'s FormData: `body.append("conversation_token", conversationToken);`. (Per-page-load = one conversation per visit.)

- [ ] **Step 4: request specs** (extend the federation spec): with `chat_retention` on, a federation POST persists a `Chat::Turn` under a Conversation (matched by `conversation_token`); a second POST with the same token appends ordinal 2; with retention OFF, no `Chat::Turn` rows are created and the SSE body is unchanged (byte-identity). Reset `chat_retention` in the `after` hook.

- [ ] **Step 5: full suite + JS goldens green; commit** — `git commit -m "v0.39: capture federation turns (tee'd sink + Recorder), Eval records, client conversation_token (gated)"`.

---

## Phase 1b — re-stream replay + browse

### Task 4: replay endpoint

**Files:** `config/routes.rb`, `app/controllers/enliterator/conversation_controller.rb` (or a new `ConversationsController`), `spec/requests/enliterator/conversation_replay_spec.rb`.

- [ ] **Step 1: route** — `get "chat/replay/:id", to: "conversation#replay", as: :conversation_replay`.
- [ ] **Step 2: action** — gated on `chat_retention` (404 off). Loads the Conversation (by id or token), sets SSE headers, and re-emits each turn's events through `sse`, in order, with a small inter-`token` delay so the answer streams; emit a `user` marker event before each turn's events so the client renders the patron bubble. Close the stream at the end. Use `ActionController::Live` (already included).
```ruby
    def replay
      return head :not_found unless Enliterator.configuration.chat_retention
      conv = Enliterator::Chat::Conversation.find_by(id: params[:id]) ||
             Enliterator::Chat::Conversation.find_by!(token: params[:id])
      response.headers["Content-Type"]  = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
      conv.turns.each do |turn|
        sse(:replay_user, q: turn.question)         # client renders the patron bubble + a fresh turn
        Array(turn.events).each do |e|
          sse(e["event"], e["data"] || {})
          sleep 0.012 if e["event"] == "token"      # animate the stream (skippable via a speed param later)
        end
      end
      sse(:replay_end, {})
    rescue ActiveRecord::RecordNotFound
      sse(:error, message: "conversation not found") rescue nil
    ensure
      response.stream.close
    end
```
> NOTE: `sse` writes `data.to_json`; the stored `e["data"]` is already a Hash (from jsonb) → re-serialized fine. The `:done` events inside each turn's stored stream are harmless on replay (the client treats per-turn done as it does live). Confirm the client tolerates multiple `done`s across turns (each turn is its own bubble).

- [ ] **Step 3: spec** — replay of a 2-turn conversation emits `event: replay_user` twice, the stored `token`/`followups` events, and `replay_end`; 404 when retention off.
- [ ] **Step 4: commit** — `git commit -m "v0.39: re-stream replay endpoint (re-emits stored events as SSE)"`.

### Task 5: replay client + browse/label surface

**Files:** `app/views/enliterator/conversation/index.html.erb` (or a small replay view), `app/controllers/enliterator/conversations_controller.rb`, `app/views/enliterator/conversations/index.html.erb`, `config/routes.rb`, layout nav.

- [ ] **Step 1: replay client** — a replay page (e.g. `/enliterator/chat/replay/:id` rendered as the chat page in "replay mode", OR the chat page reading a `?replay=:id` param) that, on load, `fetch`es the replay SSE endpoint and feeds frames through the EXISTING `handleFrameFederated`/`buildTurn`/`finishTurnFederated`. Add handling for the two replay-only events: `replay_user` → render the patron bubble + start a new turn (call the same `buildTurn`/`userBubble` path); `replay_end` → stop. Reuse everything else. No second renderer.
- [ ] **Step 2: browse/label surface** — `ConversationsController#index` (gated): lists conversations (label, context, source, turn count, updated_at) newest-first, each linking to its replay URL; `#update` sets/edits `label`; optional `#destroy`. Routes `resources` (index/update/destroy) under the gate. View composes from layout components. Nav link `Conversations` gated on `chat_retention`.
- [ ] **Step 3: request spec** — index lists a saved conversation; update sets a label; gated 404 when off; nav link only when on.
- [ ] **Step 4: node --check the rendered script + JS goldens; full suite; commit** — `git commit -m "v0.39: replay client (reuses the federated renderer) + /conversations browse + label"`.

---

### Task 6: regression sweep + final review
- [ ] Byte-identity (retention off): federation + loop + conversation_federation specs green unchanged; the off-view emits no retention DOM/JS/nav. Full `bundle exec rspec` + JS goldens.
- [ ] Fresh read-only final reviewer over the whole feature — seams: capture tee is byte-identical when off; the event-hash shape matches between capture → Recorder → DB → replay; replay re-emits faithfully and the client renders it; persona_id links correctly; recorder never raises into the request; gating (404 + no nav) holds; XSS (labels/questions escaped in the browse + replay views).
- [ ] Address findings; commit.

### Task 7: HSDL adopt + live-verify (Jeremy-gated — restart)
- [ ] Migrate HSDL dev (`bin/rails db:migrate` — the two new tables).
- [ ] `c.chat_retention = true` in HSDL initializer; restart.
- [ ] Live-verify: run a `/enliterator/chat` turn → a `Chat::Turn` persists (check `/enliterator/conversations` lists it); open its replay URL → the trace animates and the answer re-streams without a live Bedrock call; label it; confirm a second turn appends (ordinal 2); confirm `persona_id` is set when a desk is overridden. Confirm retention-off (toggle) leaves the desk byte-identical.
- [ ] Commit HSDL (gated).

## Verification
- `bundle exec rspec` green (≈ 700+); JS goldens green; `node --check` on the rendered script.
- Retention off ⇒ no capture, replay/browse 404, no nav link, chat byte-identical to v0.38.
- Live: turn persists → replay re-streams from store (no Bedrock) → label + multi-turn append → persona_id links.

## Out of scope (named)
v2 conversation-tending (Turn-as-Tendable + quality facets); pruning/caps; single-shot-path retention; patron privacy posture; SPEC.md/About (commit-only).
