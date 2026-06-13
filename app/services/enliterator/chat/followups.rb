# app/services/enliterator/chat/followups.rb
# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.35 Stage C: the inline follow-up protocol. The model ends its final
    # answer with SENTINEL on its own line, then up to three next-questions (one
    # per line). This module is the single source of truth for that shape: the
    # DIRECTIVE the Loop injects, and the parser the Loop runs on the answer.
    # Pure — no Rails, no I/O — so the contract is unit-testable in isolation.
    module Followups
      SENTINEL = "%%FOLLOWUPS%%"
      MAX = 3

      # .freeze because heredoc interpolation (#{SENTINEL}) yields an unfrozen
      # string even under frozen_string_literal — match the file's discipline.
      DIRECTIVE = <<~TXT.strip.freeze
        When you have completely finished your answer, append a final block so the
        reader can navigate onward. On its own line, write exactly:

        #{SENTINEL}

        Then write up to three short questions — one per line, no numbering or
        bullets — that the reader could naturally ask NEXT given the answer you just
        gave. Make them specific to this answer, not generic. Put nothing after the
        last question. If no genuinely useful follow-up exists, omit the block entirely.
      TXT

      # Parse the questions out of an answer's trailing sentinel block. Returns
      # [] when the block is absent or empty (the caller falls back to static
      # starters — rule 3). Splits on the FIRST sentinel occurrence, strips
      # bullet/number prefixes, drops blanks, caps at MAX.
      def self.parse(text)
        s = text.to_s
        i = s.index(SENTINEL)
        return [] if i.nil?
        s[(i + SENTINEL.length)..]
          .to_s
          .split(/\r?\n/)
          .take_while { |line| !line.include?(SENTINEL) }
          .map { |line| line.sub(/\A\s*(?:[-*]|\d+[.)])\s*/, "").strip }
          .reject(&:empty?)
          .first(MAX)
      end
    end
  end
end
