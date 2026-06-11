module Enliterator
  module Tending
    # v0.25: the READING — one librarian's session over one whole record.
    #
    # How a scholar actually reads a dense work: survey the structure, work
    # through the parts taking notes, then synthesize. This orchestrator does
    # exactly that with the existing machinery:
    #
    #   1. Section  — the host's `to_enliterator_parts` contract supplies
    #      [{heading:, text:}] in document order; Part.refresh_for! reconciles.
    #   2. Read     — each part is tended on the analysis facet (a plain
    #      Visitor pass: vocabulary, escalation, suggestions, provenance all
    #      apply). A part whose content is unchanged since its last succeeded
    #      read is SKIPPED — re-reading an unchanged section is pure NOOP
    #      spend (the v0.14 verdict, applied inside the document).
    #   3. Place    — each part gets a `kind: "part"` embedding (deliberately
    #      not "primary": parts stay out of the retrieval pools until a
    #      surface is built to read them; the vectors accrue now).
    #   4. Synthesize — the work-level facets in +synthesizes+ are re-tended
    #      on the RECORD. The host's `to_enliterator_text` returns the
    #      notebook (Part.notebook_for) once notes exist, so the deepening
    #      supersedes the front-matter understanding IN PLACE — visible in
    #      "Understanding over time", comparable by Trajectory::Judge.
    #
    # Deliberately NOT wired to the heartbeat in v0.25: the analysis facet is
    # declared `scheduled: false` and readings run by explicit invocation
    # (the pilot rake). Planner integration is gated on the pilot's verdict.
    class Reading
      def initialize(record, facet: "analysis", context: nil, synthesizes: [],
                     llm: nil, embedder: Enliterator.embedder,
                     heartbeat: nil, reason: "deep_read")
        @record      = record
        @facet       = facet.to_s
        @context     = context
        @synthesizes = Array(synthesizes).map(&:to_s)
        @llm         = llm
        @embedder    = embedder
        @heartbeat   = heartbeat
        @reason      = reason
      end

      # Returns an honest summary:
      #   { parts:, tended:, skipped:, embedded:, synthesized:, tokens:, visits: }
      # or { skipped: :no_parts } when the host yields no sections (logged why
      # — rule 3: every early return says so).
      def call
        sections = sections_for(@record)
        if sections.empty?
          Enliterator.logger&.info(
            "[enliterator] reading skipped for #{@record.class.name}/#{@record.id} — " \
            "no parts (host returned none from to_enliterator_parts)"
          )
          return { skipped: :no_parts }
        end

        parts  = Enliterator::Part.refresh_for!(@record, sections)
        visits = []
        tended = skipped = embedded = failed = synthesized = 0

        parts.each do |part|
          if fresh?(part)
            skipped += 1
          else
            begin
              visits << part.tend!(facet: @facet, context: @context, llm: @llm,
                                   embedder: @embedder, heartbeat: @heartbeat,
                                   reason: @reason)
              tended += 1
            rescue StandardError => e
              failed += 1
              Enliterator.logger&.warn(
                "[enliterator] reading: part #{part.ordinal} of " \
                "#{@record.class.name}/#{@record.id} failed — #{e.class}: #{e.message}"
              )
              # Nothing read yet and three straight failures = misconfiguration,
              # not bad luck (the heartbeat's early-abort rule). Stop spending.
              if tended.zero? && failed >= 3
                return { parts: parts.size, tended: 0, skipped: skipped, failed: failed,
                         embedded: embedded, synthesized: 0, tokens: tokens_for(visits),
                         visits: visits.compact.map(&:id), aborted: "first #{failed} reads failed" }
              end
            end
          end
          embedded += 1 if ensure_part_embedding(part)
        end

        @synthesizes.each do |facet|
          visits << @record.tend!(facet: facet, context: @context, llm: @llm,
                                  embedder: @embedder, heartbeat: @heartbeat,
                                  reason: @reason)
          synthesized += 1
        rescue StandardError => e
          failed += 1
          Enliterator.logger&.warn(
            "[enliterator] reading: synthesis #{facet} on " \
            "#{@record.class.name}/#{@record.id} failed — #{e.class}: #{e.message}"
          )
        end

        {
          parts:       parts.size,
          tended:      tended,
          skipped:     skipped,
          failed:      failed,
          embedded:    embedded,
          synthesized: synthesized,
          tokens:      tokens_for(visits),
          visits:      visits.compact.map(&:id)
        }
      end

      private

      def sections_for(record)
        return [] unless record.respond_to?(:to_enliterator_parts)
        Array(record.to_enliterator_parts)
      end

      # Unchanged content + a succeeded read = nothing new to learn. The
      # digest moved iff refresh_for! updated the row, so updated_at vs the
      # last succeeded visit is the same source-change predicate the
      # heartbeat uses on records.
      def fresh?(part)
        last = part.enliterator_visits
                   .where(facet: @facet, status: "succeeded")
                   .maximum(:started_at)
        last.present? && part.updated_at <= last
      end

      # One vector per part per content version. kind "part" keeps these out
      # of every "primary" retrieval pool. A nil vector (degraded embedder)
      # skips with a log line — never a fake row. The embedding is AUXILIARY
      # to the reading: a transient embed failure (v0.26.2 — a live gateway
      # credential-rotation blip killed a whole session through this call)
      # warns and moves on; the next reading re-embeds (the content hash
      # won't match).
      def ensure_part_embedding(part)
        existing = part.enliterator_embeddings.find_by(kind: "part")
        return false if existing && existing.content_hash == part.content_digest

        vector =
          begin
            @embedder.embed(part.enliterator_text)
          rescue StandardError => e
            Enliterator.logger&.warn(
              "[enliterator] part embedding failed for Part/#{part.id} — " \
              "#{e.class}: #{e.message} — continuing the reading"
            )
            nil
          end
        if vector.nil?
          Enliterator.logger&.warn(
            "[enliterator] part embedding skipped for Part/#{part.id} — embedder returned nil"
          )
          return false
        end

        attrs = { embedding: vector, content_hash: part.content_digest,
                  dimensions: vector.size,
                  model: @embedder.respond_to?(:model_id) ? @embedder.model_id : @embedder.class.name }
        existing ? existing.update!(**attrs) : part.enliterator_embeddings.create!(kind: "part", **attrs)
        true
      end

      # The whole session's spend: each returned visit plus its escalation
      # chain (junior rows are separate visits with their own tokens).
      def tokens_for(visits)
        visits.compact.sum do |visit|
          chain = [ visit ]
          chain << chain.last.escalated_from while chain.last&.escalated_from
          chain.compact.sum { |v| v.tokens.is_a?(Hash) ? v.tokens["total"].to_i : 0 }
        end
      end
    end
  end
end
