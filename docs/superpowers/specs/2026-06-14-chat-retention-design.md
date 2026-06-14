# Chat Retention — Design (v0.39)

**Goal:** Persist `/enliterator/chat` conversations (the dev/demo backend) so they can be (1) re-streamed for demos without re-running live, and (2) — designed-for, built later — tended as artifacts so the desk's conversational ability becomes measured and compounding. HSDL will build its own patron-facing chat on the engine later and inherit this capability.

**Status:** Approved design (brainstorm 2026-06-14). Next: implementation plan → subagent-driven build.

## The elegant core
The Loop already emits an ordered event array (`token` / `tool_call_*` / `handoff` / `provenance` / `followups` / `done`). That array is simultaneously: the **live SSE transport**, the **retained artifact**, the **replay source**, and (v2) the **tending input**. So:
- **Capture = teeing the sink** (events go to the client AND a buffer; persist at turn end).
- **Replay = re-emitting the array** over the same SSE writer — the existing federated client cannot tell replay from live.

## Decisions (from the brainstorm)
- **Capture scope:** ALL live federation turns on `/enliterator/chat` (it's the dev/demo backend — no patron-privacy weight here) + every `Chat::Eval` run. Gated by a new `config.chat_retention` (default off → byte-identical/stateless; HSDL opts in).
- **Tending depth:** v1 = store + capture + replay, with `Chat::Turn` built **tendable-ready** (polymorphic-capable, persona-linked) but NO quality facets. Conversation-tending is v2 (named below).
- **Replay:** **re-stream** — replay the stored events over SSE so the trace spins and the answer streams as it did live. Reuses the federated client (DRY).

## Design

### Store (two engine models, tendable-ready)
- `Chat::Conversation` (`enliterator_chat_conversations`): `token` (client-generated uuid, unique index — the grouping key), `context` (grounding key or nil), `label` (nullable — name a demo exemplar), `source` (string, default `"live"`; `"eval"` for harness runs), timestamps. `has_many :turns, -> { order(:ordinal) }`.
- `Chat::Turn` (`enliterator_chat_turns`): `conversation_id`, `ordinal`, `question` (text), **`events` (jsonb — the full ordered stream, the artifact)**, and denormalized-for-query/display: `answer` (text, prose with the followups sentinel stripped), `desk_name` (the desk that composed — last `handoff.to` else the initial desk), **`persona_id`** (nullable → `enliterator_chat_personas`, the version effective when the turn ran — the keystone linking persona edits to answer quality), `elapsed_ms` (int), `budget_hit` (bool). `belongs_to :conversation`; `belongs_to :persona, optional: true`. Index `[conversation_id, ordinal]`.
  - **Tendable-ready (v2 hook):** `Turn` carries enough (question + events + answer) to `include Enliterator::Tendable` and grow conversation-quality facets later (the v0.25 `Part` pattern) — not done in v1.

### Capture — `Chat::Recorder`
`Chat::Recorder.record(conversation:, question:, events:, initial_desk:, elapsed_ms:)`:
- Derives `answer` (join `:token` deltas, split off the `Followups::SENTINEL` tail), `desk_name` (last `:handoff` `to`, else `initial_desk`), `persona_id` (`Persona.history(desk_name).first&.id`), `budget_hit` (answer includes "step budget"/"time budget"), next `ordinal`.
- Persists a `Turn` under the conversation. Pure-ish (one insert); tolerant (a malformed event array still records the question + raw events — rule 3, never lose the turn).

### Controller wiring (federation path only)
When `config.chat_retention` is on AND federation is on, the controller tees its sink:
```ruby
captured = []
sink = ->(ev, data) { captured << { "event" => ev.to_s, "data" => data }; sse(ev, data) }
# ... drive the Loop with `sink` instead of method(:sse) ...
# after run:
Chat::Recorder.record(conversation: conversation_for_request, question:, events: captured,
                      initial_desk: agent.name, elapsed_ms: …)
```
- `conversation_for_request`: `Chat::Conversation.find_or_create_by(token: params[:conversation_token])` (client-generated uuid, see below); `source: "live"`.
- Retention off ⇒ sink stays `method(:sse)` ⇒ byte-identical to v0.38. The single-shot (federation-off) path is untouched.
- `Chat::Eval` records too (`source: "eval"`) via the same `Recorder` — the eval corpus builds itself.

### Conversation grouping
The client generates a `conversation_token` (uuid) once per page load (a new conversation per visit — right for a dev/demo backend), stores it in a JS var, and posts it with every stream request. The controller find-or-creates by token and appends turns in order. (The client already manages `history`; this is one more field.)

### Re-stream replay
- **Endpoint** `GET /enliterator/chat/replay/:id` (a Conversation id or token): sets SSE headers and re-emits each turn's stored events through `sse`, in order, with a small inter-token delay so the answer visibly streams (the trace steps, then the answer streams, then sources/followups). Between turns, emits the user question marker. Gated on `chat_retention` (404 off).
- **Client:** a replay page connects to the replay endpoint (a GET-driven `fetch` + the SAME `pump`/`handleFrameFederated` path the live turn uses) — no second renderer. The user-question events render the patron bubble; the rest animate exactly as live.
- **Browse/label surface** `/enliterator/conversations`: list saved conversations (label, context, source, turn count, when), open any at its replay URL, set/edit a `label` (name an exemplar), optionally delete. Gated on `chat_retention`; behind the `/enliterator` auth wrap before staging.

### Gating & byte-identity
- `config.chat_retention` (default nil/off): no capture, no `/conversations` nav link, replay/browse 404. With it off the chat path is byte-identical to v0.38.
- Capture is federation-path only; the single-shot path is untouched.

### Migrations (rule 7)
Two reversible `create_table`s, applied to `spec/dummy` + HSDL dev.

## v1 scope (YAGNI)
Store (Conversation + Turn), Recorder, all-live + eval capture (gated), conversation grouping, re-stream replay endpoint + client, browse/label surface. `Turn` tendable-ready.

## Deferred / named
- **v2 conversation-tending:** `Turn` (or `Conversation`) as `Tendable` + conversation-quality facets (grounded? answered? register held? tool-efficient?) → tended, measured, audited conversational ability; persona×quality comparison over the corpus. The whole reason retention is "super-important now."
- Pruning/retention caps (the backend will accumulate) — a v1.1 knob, noted not built.
- Retention on the single-shot path; patron-facing privacy posture (HSDL's call when it builds its UI).
- SPEC.md/About sections (commit-only, consistent with v0.31–v0.38; doc catch-up deferred).
