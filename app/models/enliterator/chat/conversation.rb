# frozen_string_literal: true

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
