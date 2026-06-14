# Persona Editing (v0.37) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A curator edits each reference desk's persona text via `/enliterator/desks`, stored append-only and versioned with rollback, applied live (no restart). Tier/tools/routes and the engine register stay code-owned.

**Architecture:** "Code seeds, store governs" (the vocabulary authority-control pattern). `Chat.register` provides the seed; a new `Enliterator::Chat::Persona` store holds versioned overrides; `Loop#system_content` resolves `Persona.effective(name) || seed` at turn time via a shared `Chat.compose_system`. Safe to expose because the Loop, not the prompt, enforces tools/grounding.

**Tech:** Ruby 3.4.5 / Rails 8.1 engine, RSpec, ActiveRecord (table prefix `enliterator_`), inline ERB views.

**Hard rules:** (1) byte-identical when `chat_persona_editing` off + store empty; (2) 100% inline UI; (3) no silent failure (blank persona rejected, missing desk handled); (7) reversible migration applied to `spec/dummy` + HSDL.

**Design doc:** `docs/superpowers/specs/2026-06-14-persona-editing-design.md`.

---

## File structure
- Create `db/migrate/<ts>_create_enliterator_chat_personas.rb`
- Create `app/models/enliterator/chat/persona.rb` (`Enliterator::Chat::Persona`)
- Modify `app/services/enliterator/chat.rb` — add `compose_system` + `register_text` (module functions)
- Modify `app/services/enliterator/chat/loop.rb` — `system_content` delegates to `Chat.compose_system`; add `persona_for`
- Modify `lib/enliterator.rb` — `config.chat_persona_editing` + `config.chat_editor`
- Modify `config/routes.rb` — `/desks` routes
- Create `app/controllers/enliterator/desks_controller.rb`
- Create `app/views/enliterator/desks/index.html.erb`
- Modify `app/views/layouts/enliterator/application.html.erb` — gated nav link to Desks
- Specs: `spec/models/enliterator/chat/persona_spec.rb`, extend `spec/services/enliterator/chat/loop_spec.rb`, `spec/requests/enliterator/desks_spec.rb`

---

### Task 1: Migration + `Chat::Persona` model

**Files:** Create the migration, `app/models/enliterator/chat/persona.rb`, `spec/models/enliterator/chat/persona_spec.rb`.

- [ ] **Step 1: Migration** (timestamp must sort AFTER the latest existing migration — use `20260614120000` or later)

```ruby
# db/migrate/20260614120000_create_enliterator_chat_personas.rb
# v0.37: per-desk persona versions (append-only). The effective persona for a
# desk is its latest row; rollback inserts a new row copying an older version.
class CreateEnliteratorChatPersonas < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_chat_personas do |t|
      t.string :desk_name,     null: false
      t.text   :system_prompt, null: false
      t.string :editor          # who (host-supplied; nil in dev)
      t.string :note            # optional change/rollback note
      t.timestamps
    end
    add_index :enliterator_chat_personas, [ :desk_name, :created_at ]
  end
end
```

- [ ] **Step 2: Apply to the dummy** — Run: `cd spec/dummy && bin/rails db:migrate && cd ../..`
  Expected: `enliterator_chat_personas` created; `spec/dummy/db/schema.rb` updated.

- [ ] **Step 3: Failing model spec**

```ruby
# spec/models/enliterator/chat/persona_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Persona do
  it "effective returns nil when no version is stored" do
    expect(described_class.effective("CHDS Theses")).to be_nil
  end

  it "record appends a version and effective returns the latest text" do
    described_class.record(desk_name: "CHDS Theses", system_prompt: "v1 text")
    described_class.record(desk_name: "CHDS Theses", system_prompt: "v2 text", editor: "alice", note: "tighten")
    expect(described_class.effective("CHDS Theses")).to eq("v2 text")
  end

  it "scopes effective per desk" do
    described_class.record(desk_name: "Frontdesk", system_prompt: "front")
    described_class.record(desk_name: "CHDS Theses", system_prompt: "chds")
    expect(described_class.effective("Frontdesk")).to eq("front")
    expect(described_class.effective("CHDS Theses")).to eq("chds")
  end

  it "history is newest-first and carries editor/note" do
    described_class.record(desk_name: "Frontdesk", system_prompt: "a")
    described_class.record(desk_name: "Frontdesk", system_prompt: "b", editor: "bob", note: "n")
    h = described_class.history("Frontdesk").to_a
    expect(h.map(&:system_prompt)).to eq(%w[b a])
    expect(h.first.editor).to eq("bob")
    expect(h.first.note).to eq("n")
  end

  it "requires desk_name and system_prompt" do
    expect { described_class.record(desk_name: "X", system_prompt: "") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
```

- [ ] **Step 4: Run red** — `bundle exec rspec spec/models/enliterator/chat/persona_spec.rb` → FAIL (no constant / no table).

- [ ] **Step 5: Implement the model**

```ruby
# app/models/enliterator/chat/persona.rb
# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.37: a curator override of a desk's persona, stored append-only and
    # versioned. The effective persona for a desk is its latest row; the Loop
    # falls back to the registered seed when none exists ("code seeds, store
    # governs" — the vocabulary authority-control pattern). Editing voice is safe
    # because the Loop, not the prompt, enforces tools/grounding.
    class Persona < Enliterator::ApplicationRecord
      self.table_name = "enliterator_chat_personas"

      validates :desk_name, presence: true
      validates :system_prompt, presence: true

      # Versions for a desk, newest first (display ordinals computed from the
      # reverse — oldest is v1).
      def self.history(desk_name)
        where(desk_name: desk_name.to_s).order(created_at: :desc, id: :desc)
      end

      # The effective (latest) persona text for a desk, or nil when none stored.
      def self.effective(desk_name)
        history(desk_name).limit(1).pick(:system_prompt)
      end

      # Append a new version. Raises on blank (rule 3: no silent empty persona).
      def self.record(desk_name:, system_prompt:, editor: nil, note: nil)
        create!(desk_name: desk_name.to_s, system_prompt: system_prompt, editor: editor, note: note)
      end
    end
  end
end
```
> NOTE: `Enliterator::Chat` is already a module (app/services/enliterator/chat.rb). This adds `Enliterator::Chat::Persona` from app/models — Zeitwerk spans both roots for the same namespace (as it already does for chat/agent.rb in services). Confirm the engine's base class name by reading `app/models/enliterator/application_record.rb` and match it (likely `Enliterator::ApplicationRecord`).

- [ ] **Step 6: Run green** — `bundle exec rspec spec/models/enliterator/chat/persona_spec.rb` (5 examples).

- [ ] **Step 7: Commit**
```bash
git add db/migrate/20260614120000_create_enliterator_chat_personas.rb app/models/enliterator/chat/persona.rb spec/models/enliterator/chat/persona_spec.rb spec/dummy/db/schema.rb
git commit -m "v0.37: Chat::Persona — append-only versioned desk persona store"
```

---

### Task 2: `Chat.compose_system` + live persona resolution in the Loop

**Files:** Modify `app/services/enliterator/chat.rb`, `app/services/enliterator/chat/loop.rb`, extend `spec/services/enliterator/chat/loop_spec.rb`.

**Context:** `Loop#system_content` (loop.rb ~:195) currently composes `register → persona → followups` inline with a private `register_text`. Lift composition into `Chat` so the surface preview and the Loop share it, and resolve the stored override.

- [ ] **Step 1: Add module functions to `chat.rb`** (inside `module Chat`, alongside the other `module_function` methods)

```ruby
    # v0.37: compose the system content from the three layers — register →
    # persona → follow-up directive — each added only when its config is on.
    # Shared by Loop#system_content and the /desks preview (DRY). With both
    # flags off this returns the bare persona_text (byte-identical to pre-v0.36).
    def compose_system(persona_text)
      [ register_text, persona_text,
        (Enliterator::Chat::Followups::DIRECTIVE if Enliterator.configuration.chat_followups) ]
        .compact.join("\n\n")
    end

    # v0.36 register layer, lifted from the Loop. nil/false ⇒ none; true ⇒ the
    # built-in DEFAULT; a String ⇒ that custom register.
    def register_text
      r = Enliterator.configuration.chat_register
      return nil unless r
      r == true ? Enliterator::Chat::Register::DEFAULT : r.to_s
    end
```

- [ ] **Step 2: Rewrite `Loop#system_content`** + add `persona_for`; DELETE the Loop's private `register_text` (now in Chat)

```ruby
      # System content for the active agent: the engine register + the EFFECTIVE
      # persona (curator override if stored, else the registered seed) + the
      # follow-up directive. Resolved at turn time so a persona edit is live
      # without a restart. Composition lives in Chat.compose_system (shared with
      # the /desks preview).
      def system_content
        Enliterator::Chat.compose_system(persona_for(@agent))
      end

      # The effective persona text for an agent: a curator's stored override wins;
      # otherwise the registered seed ("code seeds, store governs").
      def persona_for(agent)
        Enliterator::Chat::Persona.effective(agent.name) || agent.system_prompt
      end
```
> Remove the now-duplicate `register_text` private method from loop.rb (it moved to Chat). Confirm no other Loop method calls it.

- [ ] **Step 3: Extend loop_spec** (the v0.36 register block stays green because composition is identical with no override; add a v0.37 block)

```ruby
  describe "v0.37 persona override (Chat::Persona)" do
    let(:agent) do
      Enliterator::Chat::Agent.new(
        name: "Desk", grounding: nil, system_prompt: "SEED persona.",
        tools: %w[search], tier: "cheap", routes_to: [])
    end
    def recording_llm
      Class.new do
        define_method(:converse_with_tools) do |messages:, tools:, stream: false, **|
          @seen = messages.first["content"]
          Enliterator::Adapters::LLM::Gateway::ToolTurn.new(text: "ok", tool_calls: [], assistant_message: nil, tokens: {})
        end
        attr_reader :seen
      end.new
    end

    it "uses the registered seed when no override is stored (byte-identical)" do
      llm = recording_llm
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(*) {}).run("hi")
      expect(llm.seen).to eq("SEED persona.")
    end

    it "uses the curator override when one is stored, not the seed" do
      Enliterator::Chat::Persona.record(desk_name: "Desk", system_prompt: "OVERRIDE persona.")
      llm = recording_llm
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(*) {}).run("hi")
      expect(llm.seen).to eq("OVERRIDE persona.")
      expect(llm.seen).not_to include("SEED")
    end

    it "resolves the override live across a handoff (per answering desk)" do
      Enliterator::Chat::Persona.record(desk_name: "CHDS", system_prompt: "CHDS OVERRIDE.")
      seen_on_final = nil
      turns = [ calls({ id: "1", name: "route_to", arguments: { "agent" => "CHDS" } }), "ok" ]
      llm = Object.new
      llm.define_singleton_method(:converse_with_tools) do |messages:, tools:, stream: false, **|
        t = turns.shift
        next t if t.is_a?(Enliterator::Adapters::LLM::Gateway::ToolTurn)
        seen_on_final = messages.first["content"]
        Enliterator::Adapters::LLM::Gateway::ToolTurn.new(text: t, tool_calls: [], assistant_message: nil, tokens: {})
      end
      Enliterator::Chat::Loop.new(agent: Enliterator::Chat.frontdesk, llm: llm, sink: ->(*) {}, step_cap: 4).run("hi")
      expect(seen_on_final).to eq("CHDS OVERRIDE.")  # the SPECIALIST's stored override, register/followups off here
    end
  end
```
> The `before` block registers "F"/"CHDS" with seed prompts; the override for "CHDS" must win. With register/followups off in this block, compose_system returns the bare effective persona.

- [ ] **Step 4: Run** — `bundle exec rspec spec/services/enliterator/chat/loop_spec.rb` → all green (v0.36 + new v0.37). Then full `bundle exec rspec` → green.

- [ ] **Step 5: Commit**
```bash
git add app/services/enliterator/chat.rb app/services/enliterator/chat/loop.rb spec/services/enliterator/chat/loop_spec.rb
git commit -m "v0.37: Loop resolves the effective persona (override||seed) via shared Chat.compose_system"
```

---

### Task 3: config flags + routes + `DesksController`

**Files:** Modify `lib/enliterator.rb`, `config/routes.rb`; create `app/controllers/enliterator/desks_controller.rb`; create `spec/requests/enliterator/desks_spec.rb`.

- [ ] **Step 1: Config flags** (`lib/enliterator.rb`, after `chat_register`)
```ruby
    # v0.37: gates the /enliterator/desks persona-editing surface. nil/false ⇒
    # the controller 404s (and no nav link). A write surface that changes desk
    # behavior, so opt-in. The persona STORE resolution is always live (inert
    # when empty); this gates only the editing UI.
    attr_accessor :chat_persona_editing

    # v0.37: optional auth-agnostic editor-identity seam. nil ⇒ editors recorded
    # as nil (dev). A callable ->(request) { "identity" } lets a host behind auth
    # record who edited a persona without the engine imposing an auth model.
    attr_accessor :chat_editor
```
In `initialize` (after `@chat_register = nil`):
```ruby
      @chat_persona_editing = nil
      @chat_editor = nil
```

- [ ] **Step 2: Routes** (`config/routes.rb`, near the other surfaces; always drawn, controller gates)
```ruby
  # Desks (v0.37): edit each reference desk's persona — versioned, rollback-able.
  # Always drawn; DesksController 404s when config.chat_persona_editing is off
  # (the always-draw + controller-gate convention, like chat/mcp).
  get  "desks",          to: "desks#index",    as: :desks
  post "desks/update",   to: "desks#update",   as: :desk_update
  post "desks/rollback", to: "desks#rollback", as: :desk_rollback
```

- [ ] **Step 3: Failing request spec**
```ruby
# spec/requests/enliterator/desks_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe "Desks (persona editing)", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
      c.llm_adapter = Class.new do
        def model_id = "stub"
        def converse_with_tools(**) = Enliterator::Adapters::LLM::Gateway::ToolTurn.new(text: "x", tool_calls: [], assistant_message: nil, tokens: {})
      end.new
    end
    Enliterator::Chat.reset!
    Enliterator::Chat.register(name: "Frontdesk", grounding: nil, system_prompt: "SEED front.",
                              tools: %w[search], tier: "cheap")
  end
  after do
    Enliterator.configuration.chat_persona_editing = nil
    Enliterator::Chat.reset!
  end

  it "404s when chat_persona_editing is off" do
    Enliterator.configuration.chat_persona_editing = nil
    get "/enliterator/desks"
    expect(response).to have_http_status(:not_found)
  end

  it "lists the registered desks when on" do
    Enliterator.configuration.chat_persona_editing = true
    get "/enliterator/desks"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Frontdesk")
    expect(response.body).to include("SEED front.")  # the effective (seed) persona is shown
  end

  it "saves a new persona version and the effective text changes" do
    Enliterator.configuration.chat_persona_editing = true
    post "/enliterator/desks/update", params: { desk: "Frontdesk", system_prompt: "EDITED front." }
    expect(response).to redirect_to("/enliterator/desks")
    expect(Enliterator::Chat::Persona.effective("Frontdesk")).to eq("EDITED front.")
  end

  it "rejects a blank persona (rule 3)" do
    Enliterator.configuration.chat_persona_editing = true
    post "/enliterator/desks/update", params: { desk: "Frontdesk", system_prompt: "   " }
    expect(Enliterator::Chat::Persona.effective("Frontdesk")).to be_nil
    follow_redirect!
    expect(response.body).to include("can&#39;t be blank").or include("can't be blank")
  end

  it "rolls back to a prior version by appending a new version with that text" do
    Enliterator.configuration.chat_persona_editing = true
    v1 = Enliterator::Chat::Persona.record(desk_name: "Frontdesk", system_prompt: "V1.")
    Enliterator::Chat::Persona.record(desk_name: "Frontdesk", system_prompt: "V2.")
    post "/enliterator/desks/rollback", params: { desk: "Frontdesk", version_id: v1.id }
    expect(Enliterator::Chat::Persona.effective("Frontdesk")).to eq("V1.")
    expect(Enliterator::Chat::Persona.history("Frontdesk").count).to eq(3)  # append-only
  end

  it "records the editor via config.chat_editor when set" do
    Enliterator.configuration.chat_persona_editing = true
    Enliterator.configuration.chat_editor = ->(_req) { "curator@example.gov" }
    post "/enliterator/desks/update", params: { desk: "Frontdesk", system_prompt: "X." }
    expect(Enliterator::Chat::Persona.history("Frontdesk").first.editor).to eq("curator@example.gov")
  ensure
    Enliterator.configuration.chat_editor = nil
  end
end
```

- [ ] **Step 4: Run red** — `bundle exec rspec spec/requests/enliterator/desks_spec.rb` (routing/controller missing).

- [ ] **Step 5: Implement the controller**
```ruby
# app/controllers/enliterator/desks_controller.rb
# frozen_string_literal: true

module Enliterator
  # v0.37: the persona-editing surface. Edits each registered desk's persona,
  # stored versioned via Chat::Persona; tier/tools/routes and the register stay
  # code-owned and read-only here. Gated on config.chat_persona_editing (404 off).
  class DesksController < ApplicationController
    before_action :require_editing!

    def index
      @desks = Enliterator::Chat.agents.sort_by(&:name)
    end

    def update
      desk = desk_or_redirect or return
      text = params[:system_prompt].to_s
      if text.strip.empty?
        redirect_to(desks_path, alert: "Persona text can't be blank."); return
      end
      Enliterator::Chat::Persona.record(
        desk_name: desk.name, system_prompt: text,
        editor: resolve_editor, note: params[:note].presence)
      redirect_to desks_path, notice: "Saved a new persona version for #{desk.name}."
    end

    def rollback
      desk = desk_or_redirect or return
      version = Enliterator::Chat::Persona.where(desk_name: desk.name).find_by(id: params[:version_id])
      unless version
        redirect_to(desks_path, alert: "That version no longer exists."); return
      end
      Enliterator::Chat::Persona.record(
        desk_name: desk.name, system_prompt: version.system_prompt,
        editor: resolve_editor, note: "rolled back to the #{version.created_at.to_date} version")
      redirect_to desks_path, notice: "Rolled #{desk.name} back to an earlier version (saved as the latest)."
    end

    private

    def require_editing!
      head :not_found unless Enliterator.configuration.chat_persona_editing
    end

    def desk_or_redirect
      desk = Enliterator::Chat.registry[params[:desk].to_s]
      redirect_to(desks_path, alert: "No such desk: #{params[:desk]}.") unless desk
      desk
    end

    # Auth-agnostic: use the host's editor resolver if configured, else nil.
    def resolve_editor
      r = Enliterator.configuration.chat_editor
      return nil unless r.respond_to?(:call)
      r.call(request).presence
    rescue StandardError => e
      Enliterator.logger&.warn("[enliterator] chat_editor resolver raised: #{e.class}")
      nil
    end
  end
end
```

- [ ] **Step 6: Run green** — `bundle exec rspec spec/requests/enliterator/desks_spec.rb` (the index "SEED front." assertion needs the view from Task 4 — if it fails ONLY on that line, proceed to Task 4 then re-run; the other examples should pass). Then full suite green.

- [ ] **Step 7: Commit**
```bash
git add lib/enliterator.rb config/routes.rb app/controllers/enliterator/desks_controller.rb spec/requests/enliterator/desks_spec.rb
git commit -m "v0.37: /desks routes + DesksController (gated, versioned save/rollback, editor seam)"
```

---

### Task 4: The `/desks` view + gated nav link

**Files:** Create `app/views/enliterator/desks/index.html.erb`; modify the layout's nav.

- [ ] **Step 1: The view** — per desk: read-only org-chart + register, editable persona form, composed-prompt preview, version history with rollback. Compose from layout components; page `<style>` for layout only.

```erb
<%# v0.37: persona editing. Each desk's voice is editable + versioned; tier/tools/
    routes and the engine register are code-owned (shown read-only). The composed
    preview is exactly what the Loop sends (Chat.compose_system). %>
<% content_for :head do %>
<style>
  .desk { border: 1px solid var(--line); border-radius: var(--r); padding: var(--s3); margin-bottom: var(--s4); box-shadow: var(--shadow); }
  .desk__meta { font-size: var(--fs-sm); color: var(--muted); margin-bottom: var(--s2); }
  .desk__ro { background: var(--bg-soft); border-radius: var(--r-sm); padding: var(--s2) var(--s3); white-space: pre-wrap; font-size: var(--fs-sm); margin: var(--s2) 0; }
  .desk__ta { width: 100%; min-height: 12rem; font: inherit; padding: var(--s2); }
  .desk__hist { list-style: none; padding: 0; margin: var(--s2) 0 0; }
  .desk__hist li { display: flex; gap: var(--s2); align-items: baseline; padding: var(--s1) 0; border-top: 1px solid var(--line); font-size: var(--fs-sm); }
  .desk__v { font-variant-numeric: tabular-nums; color: var(--accent); font-weight: 700; }
</style>
<% end %>

<h1 class="section-head">Reference desks</h1>
<p class="muted">Edit each desk's persona — the voice and role it speaks in. The engine register and the org chart (tier, tools, routing) are code-owned and shown for context. Saves are versioned; roll back anytime. Changes are live on the next turn.</p>

<% if @desks.empty? %>
  <p class="muted">No desks are registered. (Set <code>config.chat_federation</code> and register agents.)</p>
<% end %>

<% @desks.each do |desk| %>
  <% effective = Enliterator::Chat::Persona.effective(desk.name) || desk.system_prompt %>
  <% overridden = Enliterator::Chat::Persona.effective(desk.name).present? %>
  <% history = Enliterator::Chat::Persona.history(desk.name).to_a %>
  <section class="desk">
    <h2><%= desk.name %></h2>
    <div class="desk__meta">
      tier <code><%= desk.tier %></code> ·
      tools <%= desk.tools.join(", ") %>
      <%= " · routes to #{desk.routes_to.join(', ')}" if desk.routes_to.any? %>
      · <%= overridden ? "curator override active" : "using the registered seed" %>
    </div>

    <details>
      <summary>Engine register (read-only)</summary>
      <div class="desk__ro"><%= Enliterator::Chat.register_text || "(register off)" %></div>
    </details>

    <%= form_with url: desk_update_path, method: :post do %>
      <input type="hidden" name="desk" value="<%= desk.name %>">
      <label>Persona
        <textarea name="system_prompt" class="desk__ta"><%= effective %></textarea>
      </label>
      <input type="text" name="note" placeholder="change note (optional)" class="field">
      <button type="submit" class="btn btn-affirmative">Save new version</button>
    <% end %>

    <details>
      <summary>Composed prompt the desk receives (preview)</summary>
      <div class="desk__ro"><%= Enliterator::Chat.compose_system(effective) %></div>
    </details>

    <% if history.any? %>
      <h3>History</h3>
      <ul class="desk__hist">
        <% total = history.size %>
        <% history.each_with_index do |v, i| %>
          <li>
            <span class="desk__v">v<%= total - i %></span>
            <span class="muted"><%= v.created_at.strftime("%Y-%m-%d %H:%M") %><%= " · #{v.editor}" if v.editor.present? %><%= " · #{v.note}" if v.note.present? %></span>
            <%= form_with url: desk_rollback_path, method: :post do %>
              <input type="hidden" name="desk" value="<%= desk.name %>">
              <input type="hidden" name="version_id" value="<%= v.id %>">
              <button type="submit" class="btn">Roll back to this</button>
            <% end %>
          </li>
        <% end %>
      </ul>
    <% end %>
  </section>
<% end %>
```
> NOTE: confirm the layout token/component names used here (`--line`, `--r`, `--shadow`, `--bg-soft`, `.section-head`, `.btn`, `.btn-affirmative`, `.field`, `.muted`) exist in the layout `<style>`; substitute the real names where they differ. All values escaped by ERB by default (persona text via `<%= %>` is HTML-escaped — an XSS-safe surface).

- [ ] **Step 2: Gated nav link** — in the layout nav, add a Desks link only when editing is on. Find the nav `<a>` list in `app/views/layouts/enliterator/application.html.erb` and add:
```erb
<% if Enliterator.configuration.chat_persona_editing %><%= link_to "Desks", desks_path %><% end %>
```
(Place it near the Settings link; match the existing nav-link markup exactly.)

- [ ] **Step 3: Re-run the request spec** — `bundle exec rspec spec/requests/enliterator/desks_spec.rb` → all green (the index "SEED front." assertion now passes). Full suite green.

- [ ] **Step 4: Commit**
```bash
git add app/views/enliterator/desks/index.html.erb app/views/layouts/enliterator/application.html.erb
git commit -m "v0.37: /desks view — per-desk persona editor, composed preview, version history + rollback"
```

---

### Task 5: Regression sweep + final review

- [ ] **Step 1: Byte-identity check** — confirm the federation OFF view + the existing loop/federation specs are unchanged:
  `bundle exec rspec spec/requests/enliterator/conversation_federation_spec.rb spec/services/enliterator/chat` → green. The persona store empty + `chat_persona_editing` off ⇒ `compose_system` returns the same as v0.36.

- [ ] **Step 2: Full suite + JS goldens**
  `bundle exec rspec` (663 + new ~16) and `for f in spec/javascript/*.test.js; do node "$f" || exit 1; done`.

- [ ] **Step 3: Dispatch a fresh read-only final reviewer** over the whole feature (model, compose_system, loop resolution, controller, view) — focus seams: the override-wins resolution is live per turn and per handoff; blank/absent-desk/absent-version handled (rule 3); the view escapes persona text (XSS); `chat_persona_editing` off ⇒ 404 + no nav link + byte-identical compose; the editor seam never raises into a request.

- [ ] **Step 4: Address findings; commit any fixes.**

---

### Task 6: HSDL adopt + live-verify (Jeremy-gated — restart)

- [ ] **Step 1: Apply the migration to HSDL dev** — `cd ../hsdl-ai && bin/rails db:migrate` (creates `enliterator_chat_personas`).
- [ ] **Step 2: Opt in** — in HSDL `config/initializers/enliterator.rb`: `c.chat_persona_editing = true`, and optionally `c.chat_editor = ->(req) { req.env["warden"]&.user&.email rescue nil }` (or leave nil in dev). Restart: `bin/restart web`.
- [ ] **Step 3: Live-verify** at `http://localhost:3055/enliterator/desks`:
  - Both desks listed with their seed personas + read-only org-chart/register + composed preview.
  - Edit the CHDS persona (e.g. add a sentence), save → a turn at `/enliterator/chat` reflects the edited voice on the NEXT turn (hot-swap, no restart).
  - Roll back → the prior voice returns; history shows the rollback as a new version.
  - An un-edited desk still uses its seed.
- [ ] **Step 4: Commit HSDL** (gated) — initializer + Gemfile.lock repin to the pushed v0.37 engine.

## Verification
- `bundle exec rspec` green (≈ 679); JS goldens green.
- `chat_persona_editing` off ⇒ `/desks` 404, no nav link, chat behavior byte-identical to v0.36.
- Live: edit → live on next turn; rollback works; seed fallback for un-edited desks.

## Out of scope (named)
Register editing in the UI; version diff view; A/B personas; the enliterate-the-handbook horizon; SPEC.md/About (commit-only, doc catch-up deferred).
