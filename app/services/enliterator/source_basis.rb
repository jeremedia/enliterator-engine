# frozen_string_literal: true

module Enliterator
  # v0.82 — WHOSE WORDS ARE THESE: the basis of a span inside the text a claim
  # was tended from.
  #
  # A located quote is only evidence of what the DOCUMENT says when the text it
  # was found in is the document's own. For a part claim it is (a section of
  # the source). For a work-level claim the host's tending text is often
  # something else: the deep-read notebook (the catalog's own reading notes)
  # or an AI summary. A span located there matches the catalog's notes, not
  # the author — and v0.79's `verbatim: located` could not tell the
  # difference. This resolves the basis so a consumer never presents
  # model-written text as the author's words.
  #
  # Bases:
  #   document_section — a Part's text (the engine owns it: a section of the source)
  #   document_text    — host-declared document text (a title page, a full-text excerpt)
  #   catalog_record   — host-declared catalog metadata (title, description/abstract)
  #   reading_notes    — the engine's deep-read notebook (model-written)
  #   ai_summary       — host-declared machine summary (model-written)
  #   undeclared       — the host has not said; only the engine's own notebook is detectable
  #
  # Hosts declare their composition with an optional
  #   enliterator_text_segments(facet:) → [{ text:, basis: }, ...]
  # whose texts joined by "\n\n" must equal enliterator_text(facet:) exactly.
  # A mismatch is ignored and logged (rule 3), never trusted.
  module SourceBasis
    module_function

    BASES        = %w[document_section document_text catalog_record reading_notes ai_summary undeclared].freeze
    MODEL_WRITTEN = %w[reading_notes ai_summary].freeze
    SEPARATOR    = "\n\n"

    # The composition of `source` (the text `record` was tended from along
    # `facet`): [{ basis:, start:, chars: }] in order. A separator belongs to
    # the segment before it. Undeclared hosts get one undeclared segment,
    # split where the engine's own notebook begins.
    def layout(record, facet:, source:)
      return [ { basis: "document_section", start: 0, chars: source.length } ] if record.is_a?(Enliterator::Part)

      if (segments = declared_segments(record, facet: facet, source: source))
        offset = 0
        return segments.map do |seg|
          entry = { basis: seg[:basis], start: offset, chars: seg[:text].length }
          offset += seg[:text].length + SEPARATOR.length
          entry
        end
      end

      header = source.index(Enliterator::Part::NOTEBOOK_HEADER)
      return [ { basis: "undeclared", start: 0, chars: source.length } ] unless header

      [ { basis: "undeclared", start: 0, chars: header },
        { basis: "reading_notes", start: header, chars: source.length - header } ]
    end

    # The basis at character `at` of `source`. `at` nil (span not located)
    # answers the basis of the head of the source.
    def at(record, facet:, source:, at: nil)
      pos = at.to_i
      layout(record, facet: facet, source: source).reverse.find { |seg| seg[:start] <= pos }[:basis]
    end

    # v0.84: does this layout say anything a bare digest does not? (Only
    # "undeclared" ⇒ no: nothing worth stamping on a visit.)
    def informative?(layout) = Array(layout).any? { |seg| seg[:basis] != "undeclared" }

    # v0.84: where the document's own text begins — the first segment after the
    # catalog record (title, description). nil when the host has not declared
    # its composition (the engine cannot know where a title ends).
    def body_at(layout)
      declared = Array(layout).reject { |seg| %w[undeclared reading_notes].include?(seg[:basis]) }
      return nil if declared.empty?
      Array(layout).find { |seg| seg[:basis] != "catalog_record" }&.dig(:start)
    end

    def model_written?(basis) = MODEL_WRITTEN.include?(basis.to_s)

    def declared_segments(record, facet:, source:)
      return nil unless record.respond_to?(:enliterator_text_segments)

      raw = record.enliterator_text_segments(facet: facet)
      segs = Array(raw).filter_map do |s|
        text  = (s[:text] || s["text"]).to_s
        basis = (s[:basis] || s["basis"]).to_s
        next if text.empty?
        { text: text, basis: BASES.include?(basis) ? basis : "undeclared" }
      end
      return nil if segs.empty?

      joined = segs.map { |s| s[:text] }.join(SEPARATOR)
      if joined != source
        Enliterator.logger&.warn(
          "[enliterator] source_basis: #{record.class.name}/#{record.id} declared segments do not " \
          "reproduce enliterator_text(facet: #{facet.inspect}) — ignoring the declaration"
        )
        return nil
      end
      segs
    rescue StandardError => e
      Enliterator.logger&.warn("[enliterator] source_basis: segments raised #{e.class}: #{e.message}")
      nil
    end
  end
end
