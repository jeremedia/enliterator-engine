module Enliterator
  module Mcp
    module Tools
      # Claim → primary material: the passage of source text that backs a
      # claim, from the SAME text its tend read (a part's section, the title
      # page, the notebook). Span location is LEXICAL — exact match, then the
      # longest run of the claim's tokens, then an honest head-of-source with
      # located: false. It never fakes a quote.
      class Quote < Tool
        CHARS_MAX = 1_200
        RUN_MIN   = 3       # minimum token-run worth calling a located span
        # v0.86.2: a token window locates a span only when it holds this share of
        # the claim's distinctive words. Before, ANY 3 of up to 24 counted, so a
        # limitations claim "located" in the record's title (three title words)
        # and came back verbatim — a fabricated citation (HSDL, claim 284792).
        COVERAGE_MIN = 0.3
        SPAN_CHARS   = 1_200 # how wide a window may be to count as one span

        honors_member_scope!   # v0.83

        name_and_description "quote",
          "The source passage behind a claim — the exact text the tend read, located " \
          "lexically. Use to put primary material in front of a reader instead of " \
          "paraphrase. located:false means the span couldn't be found; what returns is " \
          "the head of the source, honestly labeled."

        schema({
          "claim_id" => int("The claim id (from record_entry)"),
          "chars"    => int("Window size (default 600, cap #{CHARS_MAX})")
        }, required: [ :claim_id ])

        def call(claim_id:, chars: 600)
          claim  = visible_claim!(claim_id)
          record = claim.tendable ||
                   raise(ArgumentError, "claim ##{claim_id}'s record no longer exists")
          window = chars.clamp(120, CHARS_MAX)

          source = record.enliterator_text(facet: claim.visit&.facet).to_s
          raise "the source text is empty — the record may be untendable (see collection_overview's condition)" if source.strip.empty?

          value   = claim.value.is_a?(String) ? claim.value : claim.value.to_json
          # v0.82: WHOSE words the span is — a located span in the catalog's own
          # reading notes or an AI summary is not the author's text.
          layout  = Enliterator::SourceBasis.layout(record, facet: claim.visit&.facet, source: source)
          located, start, hit, located_by = locate(source, claim.value, layout)
          start ||= 0
          # v0.86.1: the excerpt stays inside the segment the span sits in. The
          # window opens 80 chars before the hit and could run from an abstract
          # into the reading notes under ONE basis label (HSDL found it live).
          # A single-segment source is unchanged.
          seg     = layout.reverse.find { |sg| sg[:start] <= (hit || 0) }
          seg_end = seg[:start] + seg[:chars]
          start   = [ start, seg[:start] ].max
          excerpt = source[start, [ window, seg_end - start ].min]
          basis   = Enliterator::SourceBasis.at(record, facet: claim.visit&.facet, source: source, at: hit)
          model_written = Enliterator::SourceBasis.model_written?(basis)
          # v0.84: the composition itself, so a consumer can attribute any span
          # exactly — and where the document's own text begins (after title and
          # description). Both absent when the host has declared nothing.
          segments = Enliterator::SourceBasis.informative?(layout) && !record.is_a?(Enliterator::Part) ? layout : nil
          body_at  = Enliterator::SourceBasis.body_at(layout) unless record.is_a?(Enliterator::Part)

          digest = Digest::MD5.hexdigest(source)
          stamped = Enliterator::Audit.where(claim_id: claim.id).order(:created_at)
                                      .pick(:source_digest)
          # v0.79: under chat_attribution the two texts are NAMED for what they are
          # — the catalog's claim vs the document's own words — so an agent cannot
          # blend them into one "quotation". `verbatim` is true only when the span
          # was located; an unlocated head-of-source is still the document's text
          # but is NOT evidence for this claim. Flag-off: the pre-v0.79 shape.
          if Enliterator.configuration.chat_attribution
            return {
              catalog_claim: { id: claim.id, key: claim.key, value: render_value(claim.value, cap: nil),
                               nature: claim_nature(claim) },
              source_passage: excerpt,
              # v0.82: verbatim = located AND not model-written. A span found in
              # the reading notes or an AI summary is the catalog's words.
              verbatim: located && !model_written,
              located: located,
              located_by: located_by,
              basis: basis,
              model_written: model_written,
              segments: segments,
              body_at: body_at,
              at_chars: start,
              source_chars: source.length,
              source_digest: digest,
              source_drifted: (stamped && stamped != digest) || nil,
              next: { provenance: "the claim's full chain" }
            }.compact
          end

          {
            claim: { id: claim.id, key: claim.key, value: render_value(claim.value, cap: nil) },
            located: located,
            located_by: located_by,
            passage: excerpt,
            basis: basis,
            model_written: model_written,
            segments: segments,
            body_at: body_at,
            at_chars: start,
            source_chars: source.length,
            source_digest: digest,
            source_drifted: (stamped && stamped != digest) || nil,
            next: { provenance: "the claim's full chain" }
          }.compact
        end

        private

        # How a span is found, strongest first, named in `located_by`:
        #   exact_text    — the claim's whole value appears verbatim
        #   exact_element — one element of an array value appears verbatim
        #   word_overlap  — a window of ≤ SPAN_CHARS holds at least COVERAGE_MIN of
        #                   the claim's distinctive words (and at least RUN_MIN)
        # Anything weaker is NOT a location — an inferred or classifying claim
        # ("Barack Obama" as issuing president, a thematic cluster) honestly has
        # no passage, and a guess presented as one is worse than none.
        # Returns [located, window_start, hit, located_by]; `hit` is where the
        # span begins (SourceBasis needs it; the window opens 80 chars earlier).
        def locate(source, value, layout = [ { basis: "undeclared", start: 0, chars: source.length } ])
          text = value.is_a?(String) ? value : value.to_json
          idx = source.index(text)
          return [ true, [ idx - 80, 0 ].max, idx, "exact_text" ] if idx

          if value.is_a?(Array)
            down = source.downcase
            value.each do |el|
              next unless el.is_a?(String) && el.strip.length >= 4
              i = down.index(el.strip.downcase)
              return [ true, [ i - 80, 0 ].max, i, "exact_element" ] if i
            end
          end

          # An array's elements are independent statements (four related titles):
          # each must locate on its own — pooled, their common words ("executive",
          # "order", "government") land on the record's OWN title.
          texts = value.is_a?(Array) ? value.grep(String) : [ text ]
          texts.each do |t|
            at = overlap_at(source, t, layout)
            return [ true, [ at - 80, 0 ].max, at, "word_overlap" ] if at
          end
          [ false, nil, nil, nil ]
        end

        # Where a window of ≤ SPAN_CHARS holds ≥ COVERAGE_MIN of the text's
        # distinctive words (≥ RUN_MIN) — and, when the text carries numbered
        # tokens (an order number, a section), at least one of them: numbers
        # carry identity, so EO 13423 never "locates" in a passage about 13450.
        #
        # A span lies inside ONE text: the window is scored per segment of the
        # composition (title, abstract, AI summary, reading notes), so words from
        # the title and the abstract never add up to one "span" — and the excerpt,
        # clipped to the hit's segment (v0.86.1), shows the evidence, not just the
        # title. Ties prefer the author's text over model-written text.
        def overlap_at(source, text, layout)
          tokens = text.scan(/[A-Za-z0-9][A-Za-z0-9'-]{3,}/).map(&:downcase).uniq.first(24)
          return nil if tokens.size < RUN_MIN

          need     = [ RUN_MIN, (tokens.size * COVERAGE_MIN).ceil ].max
          numbered = tokens.select { |t| t.match?(/\d/) }.to_set
          hits = tokens.flat_map do |t|
            source.to_enum(:scan, /\b#{Regexp.escape(t)}\b/i).map { [ Regexp.last_match.begin(0), t ] }
          end.sort_by(&:first)
          return nil if hits.map(&:last).uniq.size < need

          scored = layout.filter_map do |seg|
            inside = hits.select { |pos, _| pos >= seg[:start] && pos < seg[:start] + seg[:chars] }
            count, at = densest(inside, numbered)
            [ count, Enliterator::SourceBasis.model_written?(seg[:basis]) ? 0 : 1, -seg[:start], at ] if count >= need
          end
          scored.max_by { |count, authored, neg_start, _| [ count, authored, neg_start ] }&.last
        end

        # The most distinct tokens within SPAN_CHARS over sorted [pos, token]
        # hits → [count, start_of_that_window]. With numbered tokens in play, a
        # window counts only if it holds one of them.
        def densest(hits, numbered)
          best, best_at, lo, counts = 0, nil, 0, Hash.new(0)
          hits.each do |pos, tok|
            counts[tok] += 1
            while pos - hits[lo][0] > SPAN_CHARS
              t = hits[lo][1]; counts[t] -= 1; counts.delete(t) if counts[t].zero?; lo += 1
            end
            next if numbered.any? && (counts.keys & numbered.to_a).empty?
            best, best_at = counts.size, hits[lo][0] if counts.size > best
          end
          [ best, best_at ]
        end
      end
    end
  end
end
