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

  get "status", to: "status#index", as: :status
  # Per-record drill-down. :type/:id are separate segments so polymorphic, possibly
  # non-integer (uuid) host PKs survive routing; the id constraint allows dots/uuids.
  get "status/:type/:id", to: "status#show", as: :status_record, constraints: { id: %r{[^/]+} }

  get  "chat",        to: "conversation#index",  as: :conversation
  post "chat/stream", to: "conversation#stream", as: :conversation_stream

  # The pulse monitor (v0.16): trigger a heartbeat cycle and watch it live.
  # `beat` opens + runs a cycle in a background thread; `pulse` is the JSON
  # the monitor polls — BY ROW ID, never "latest" (a forced second cycle must
  # not silently switch the subject under a watching monitor).
  get  "heartbeat",           to: "heartbeat#index", as: :heartbeat
  post "heartbeat/beat",      to: "heartbeat#beat",  as: :heartbeat_beat
  get  "heartbeat/pulse/:id", to: "heartbeat#pulse", as: :heartbeat_pulse

  # Suggestion review (v0.7): the governed-vocabulary queue. Verdicts
  # (approve / map / reject) act per proposed_key.
  get  "suggestions",          to: "suggestions#index",    as: :suggestions
  post "suggestions/verdict",  to: "suggestions#verdict",  as: :suggestions_verdict
  # v0.8: run the considerer over the whole open field (auto-apply safe verdicts).
  post "suggestions/consider", to: "suggestions#consider", as: :suggestions_consider
end
