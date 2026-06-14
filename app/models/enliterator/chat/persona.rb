# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.37: a curator override of a desk's persona, stored append-only and
    # versioned. The effective persona for a desk is its latest row; the Loop
    # falls back to the registered seed when none exists ("code seeds, store
    # governs"). Editing voice is safe because the Loop, not the prompt, enforces
    # tools/grounding.
    class Persona < Enliterator::ApplicationRecord
      self.table_name = "enliterator_chat_personas"

      validates :desk_name, presence: true
      validates :system_prompt, presence: true

      # Versions for a desk, newest first.
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
