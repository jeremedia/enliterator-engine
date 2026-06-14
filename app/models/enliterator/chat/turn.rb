# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.39: one retained turn. `events` (jsonb) is the full ordered Loop event
    # stream — the artifact. Tendable-ready (question + events + answer carry
    # enough to grow conversation-quality facets later — the v0.25 Part pattern).
    class Turn < Enliterator::ApplicationRecord
      self.table_name = "enliterator_chat_turns"

      belongs_to :conversation, class_name: "Enliterator::Chat::Conversation", inverse_of: :turns
      belongs_to :persona, class_name: "Enliterator::Chat::Persona", optional: true

      validates :question, presence: true
    end
  end
end
