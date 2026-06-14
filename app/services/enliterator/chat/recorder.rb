# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.39: persist one captured turn. Derives the denormalized fields from the
    # event stream; never raises into the request (rule 3 — a bad event array still
    # records the question + raw events). Tolerates string- and symbol-keyed events
    # at every level (live transport uses string outer + symbol data; jsonb round-trip
    # produces all-string keys).
    module Recorder
      def self.record(conversation:, question:, events:, initial_desk: nil, elapsed_ms: nil)
        ev     = Array(events)
        answer = prose_of(ev)
        desk   = last_handoff(ev) || initial_desk
        Enliterator::Chat::Turn.create!(
          conversation: conversation,
          ordinal:      (conversation.turns.maximum(:ordinal) || 0) + 1,
          question:     question.to_s,
          events:       ev,
          answer:       answer,
          desk_name:    desk,
          persona_id:   (desk && Enliterator::Chat::Persona.history(desk).first&.id),
          elapsed_ms:   elapsed_ms,
          budget_hit:   answer.to_s.match?(/step budget|time budget/)
        )
      rescue StandardError => e
        Enliterator.logger&.warn("[enliterator] chat recorder failed: #{e.class}: #{e.message}")
        nil
      end

      # Join token deltas and strip the SENTINEL tail.
      def self.prose_of(ev)
        text = ev.select { |e| event_name(e) == "token" }
                 .map { |e| dig(e, "data", "t") }
                 .join
        text.to_s.split(Enliterator::Chat::Followups::SENTINEL).first.to_s.strip
      end

      # The destination of the last handoff event, or nil if none.
      def self.last_handoff(ev)
        ev.select { |e| event_name(e) == "handoff" }
          .map { |e| dig(e, "data", "to") }
          .compact
          .last
      end

      # Coerce the event name to a string; returns "" for non-hash entries (rule 3).
      def self.event_name(e)
        return "" unless e.is_a?(Hash)
        (e["event"] || e[:event]).to_s
      end

      # Tolerates string or symbol keys at each level. Returns nil on any non-hash.
      def self.dig(e, *keys)
        keys.reduce(e) do |acc, k|
          next nil unless acc.is_a?(Hash)
          acc[k] || acc[k.to_s] || acc[k.to_sym]
        end
      end
    end
  end
end
