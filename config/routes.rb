Enliterator::Engine.routes.draw do
  # The engine's mountable UI (v0.6). Hosts: `mount Enliterator::Engine => "/enliterator"`.
  root to: "status#index"

  get "status", to: "status#index", as: :status
  # Per-record drill-down. :type/:id are separate segments so polymorphic, possibly
  # non-integer (uuid) host PKs survive routing; the id constraint allows dots/uuids.
  get "status/:type/:id", to: "status#show", as: :status_record, constraints: { id: %r{[^/]+} }

  get  "chat",        to: "conversation#index",  as: :conversation
  post "chat/stream", to: "conversation#stream", as: :conversation_stream

  # Suggestion review (v0.7): the governed-vocabulary queue. Verdicts
  # (approve / map / reject) act per proposed_key.
  get  "suggestions",          to: "suggestions#index",    as: :suggestions
  post "suggestions/verdict",  to: "suggestions#verdict",  as: :suggestions_verdict
  # v0.8: run the considerer over the whole open field (auto-apply safe verdicts).
  post "suggestions/consider", to: "suggestions#consider", as: :suggestions_consider
end
