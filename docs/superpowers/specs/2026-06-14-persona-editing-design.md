# Persona Editing — Design (v0.37)

**Goal:** Let a curator edit each reference desk's persona text through a surface, stored and versioned with rollback, applied live (no restart) — without exposing the security/cost levers (tier, tools, routes) or the engine register.

**Status:** Approved design (brainstorm 2026-06-14). Next: implementation plan → subagent-driven build.

## Why this shape

The registry already embodies "code registers a default." Persona editing is the same **"code seeds, store governs"** pattern the engine uses for **vocabulary authority control** (code terms + curator-authorized terms → effective vocabulary). `Chat.register` keeps providing the seed; a new store holds curator overrides; the Loop resolves `override || seed` at turn time.

It is safe to expose because **the Loop, not the prompt, is the enforcement boundary** (allow-list before dispatch, read-only, grounding injection — v0.28). An edited persona shapes voice but can never reach a tool it isn't allowed, write to the record, or escape its grounding. That is the whole reason the voice is a thing we can hand to a curator while tier/tools/routes stay in code.

## Design

### Storage — append-only, versioned (`Enliterator::Chat::Persona`)
Table `enliterator_chat_personas`, one row per *version*:
- `desk_name` (string, indexed) — matches `Chat::Agent#name`.
- `system_prompt` (text) — the persona text for this version.
- `editor` (string, nullable) — who made the change (host-supplied; nil in dev).
- `note` (string, nullable) — optional change note / rollback marker.
- `created_at`.

Append-only: every save inserts a new row. The **effective** persona for a desk is its **latest** row (`max created_at`), falling back to the registered seed when no rows exist. Rollback is linear and honest: rolling back to version *k* inserts a *new* latest row copying *k*'s text (`note: "rolled back to v{k}"`) — history never loses a step. "Reset to default" is the same move against the current code seed (`note: "reset to seed"`).

Model API:
- `Persona.effective(desk_name) -> String | nil` (latest row's text, or nil)
- `Persona.history(desk_name) -> [rows]` newest-first (display version ordinals computed from ascending order)
- `Persona.record(desk_name:, system_prompt:, editor: nil, note: nil) -> row`

### Resolution — live, in the Loop
Extract prompt composition into one shared place so the surface preview and the Loop agree:
- `Enliterator::Chat.compose_system(persona_text) -> String` — composes `register → persona → followups directive`, each layer added only when its config is on (this is exactly today's `Loop#system_content` logic, lifted up).
- `Loop#system_content` becomes: `Enliterator::Chat.compose_system(persona_for(@agent))` where `persona_for(agent) = Persona.effective(agent.name) || agent.system_prompt`.

Read at turn time (one indexed SELECT per `system_content` call — 1–2 per turn, negligible against the LLM round-trips). An edit is live on the next turn. The `Agent` stays the immutable seed.

### Surface — `/enliterator/desks` (gated)
A new page listing every registered desk. Per desk:
- **Read-only:** the org-chart (tier, tools, routes_to) and the engine register — the parts that are NOT editable, shown so the curator sees the full picture.
- **Editable:** the persona textarea, pre-filled with the effective text, saved via `form_with method: :post` (the engine's write-surface convention; CSRF automatic).
- **Composed-prompt preview:** a read-only render of `Chat.compose_system(effective)` so the curator sees exactly what the desk receives (register + persona + directive).
- **Version history:** newest-first, each version's note/editor/when, with a "roll back to this" button.

Composes from the layout's v0.19 components; page `<style>` is page-specific layout only; 100% inline (hard rule 2).

### Gating & safety
- `config.chat_persona_editing` (NEW, default nil/off) gates the **surface** (routes + controller). A host opts in deliberately — it is a write surface that changes behavior. Mirrors the `chat_federation`/`chat_followups` discipline.
- The **resolution** (`override || seed`) is always live but inert when the store is empty → byte-identical when unused.
- The surface also sits behind the `/enliterator` auth wrap that lands before staging (deploy-gate dependency, not built here).
- **Editor identity** seam (auth-agnostic): `config.chat_editor` (NEW, default nil) — an optional callable `->(request) { identity_string }`. The controller records `editor: resolve_editor`. HSDL behind CHDS Pulse can set it to read `current_user`; dev records nil. The engine imposes no auth model.

### Byte-identity (rule 1)
With `chat_persona_editing` off and the store empty: the surface is absent (routes not drawn) and `compose_system` returns the same content `system_content` produced before — byte-identical to v0.36. Existing loop/federation specs stay green unchanged.

### Migrations (rule 7)
Reversible `create_table`. Applied to BOTH `spec/dummy` (`cd spec/dummy && bin/rails db:migrate`) and HSDL dev.

## v1 scope (YAGNI)
Per-desk persona text, versioned with rollback, live resolution, composed-prompt preview, editor seam, opt-in surface.

## Deferred (named)
- Register editing in the UI (excluded by decision — the register stays engine default / host String).
- Side-by-side version diff (the history list + preview suffices for v1).
- A/B personas, scheduled personas.
- The horizon: a persona refined by *enliterating the program's thesis handbook* (v0.28 note) — persona-as-enliterated-artifact.
- SPEC.md/About sections (commit-only, consistent with v0.31–v0.36; the doc catch-up is a separate flagged pass).
