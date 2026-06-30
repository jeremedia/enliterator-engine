Enliterator::Engine.routes.draw do
  # The engine's mountable UI (v0.6). Hosts: `mount Enliterator::Engine => "/enliterator"`.
  root to: "status#index"

  # The explainer (v0.10): what enliteracy is, why the collection is tended, and how
  # compounding attention changes it now and over time. A living document.
  get "about", to: "about#index", as: :about

  # The configuration surface (v0.11): the org chart + the accumulating vocabulary —
  # what literacy this particular enliteration has been given. Read-only.
  get "settings", to: "settings#index", as: :settings

  # The context tree (v0.13): nested enliterated collections — per-context facets,
  # members, and claim counts. The "collections within collections" view.
  get "contexts", to: "contexts#index", as: :contexts

  # The catalog (v0.24): browse and search the enliterated holdings — the OPAC
  # over what the collection has come to understand. Search by meaning through
  # Chat retrieval's pool; browse by subject heading (the vocabulary in use);
  # wander lands on a random record, the open-stacks gesture.
  get "catalog",        to: "catalog#index",  as: :catalog
  get "catalog/wander", to: "catalog#wander", as: :catalog_wander

  # The MCP endpoint (v0.26): the agent's reading-room card — the protocol
  # minimum (JSON-RPC over POST, tools only) serving provenance, trajectory,
  # and self-knowledge to conversational agents. Other verbs: 405.
  post  "mcp", to: "mcp#rpc", as: :mcp
  match "mcp", to: "mcp#method_not_allowed", via: [ :get, :put, :delete, :patch ]

  get "status", to: "status#index", as: :status
  # Per-record drill-down. :type/:id are separate segments so polymorphic, possibly
  # non-integer (uuid) host PKs survive routing; the id constraint allows dots/uuids.
  get "status/:type/:id", to: "status#show", as: :status_record, constraints: { id: %r{[^/]+} }

  get  "chat",        to: "conversation#index",  as: :conversation
  post "chat/stream", to: "conversation#stream", as: :conversation_stream
  # v0.39: re-stream replay — re-emits a saved conversation's stored events as SSE
  # so the federated client renders it identically to a live turn (gated; 404 off).
  get "chat/replay/:id", to: "conversation#replay", as: :conversation_replay, constraints: { id: %r{[^/]+} }

  # The atlas (v0.21): the enliterated collection drawn as a graph — records,
  # the entities their claims name, and the contexts that hold them; every
  # edge carries its provenance. The exported standalone file embeds the same
  # data this page does.
  get "atlas",      to: "atlas#index", as: :atlas
  get "atlas/data", to: "atlas#data",  as: :atlas_data
  # v0.4X (Stage 1): the inspector endpoint — one node's claims + provenance +
  # known gaps (lacunae) for the Ego lens drawer.
  get "atlas/node", to: "atlas#node",  as: :atlas_node

  # The pulse monitor (v0.16): trigger a heartbeat cycle and watch it live.
  # `beat` opens + runs a cycle in a background thread; `pulse` is the JSON
  # the monitor polls — BY ROW ID, never "latest" (a forced second cycle must
  # not silently switch the subject under a watching monitor).
  get  "heartbeat",           to: "heartbeat#index", as: :heartbeat
  post "heartbeat/beat",      to: "heartbeat#beat",  as: :heartbeat_beat
  get  "heartbeat/pulse/:id", to: "heartbeat#pulse", as: :heartbeat_pulse

  # Quality review (v0.18): the human anchor for the audit instrument —
  # confirm/overrule/correct the examiner's verdicts on sampled claims.
  get  "review",         to: "review#index",   as: :review
  post "review/verdict", to: "review#verdict", as: :review_verdict

  # Suggestion review (v0.7): the governed-vocabulary queue. Verdicts
  # (approve / map / reject) act per proposed_key.
  get  "suggestions",          to: "suggestions#index",    as: :suggestions
  post "suggestions/verdict",  to: "suggestions#verdict",  as: :suggestions_verdict
  # v0.8: run the considerer over the whole open field (auto-apply safe verdicts).
  # v0.48: now ASYNC — opens a ConsidererRun and redirects; the monitor polls pulse.
  post "suggestions/consider",          to: "suggestions#consider",       as: :suggestions_consider
  get  "suggestions/consider/pulse/:id", to: "suggestions#consider_pulse", as: :suggestions_consider_pulse

  # Desks (v0.37): edit each reference desk's persona — versioned, rollback-able.
  # Always drawn; DesksController 404s when config.chat_persona_editing is off
  # (the always-draw + controller-gate convention, like chat/mcp).
  get  "desks",          to: "desks#index",    as: :desks
  post "desks/update",   to: "desks#update",   as: :desk_update
  post "desks/rollback", to: "desks#rollback", as: :desk_rollback
  post "desks/reset",    to: "desks#reset",    as: :desk_reset

  # v0.39: browse + label retained conversations (gated; controller 404s when off).
  get  "conversations",            to: "conversations#index",   as: :conversations
  post "conversations/:id/label",  to: "conversations#label",   as: :conversation_label
  post "conversations/:id/delete", to: "conversations#destroy", as: :conversation_delete
end
