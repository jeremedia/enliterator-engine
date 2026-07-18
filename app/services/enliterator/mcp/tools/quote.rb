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
          claim  = Enliterator::Claim.find_by(id: claim_id) ||
                   raise(ArgumentError, "no claim ##{claim_id}")
          record = claim.tendable ||
                   raise(ArgumentError, "claim ##{claim_id}'s record no longer exists")
          window = chars.clamp(120, CHARS_MAX)

          source = record.enliterator_text(facet: claim.visit&.facet).to_s
          raise "the source text is empty — the record may be untendable (see collection_overview's condition)" if source.strip.empty?

          value   = claim.value.is_a?(String) ? claim.value : claim.value.to_json
          located, start = locate(source, value)
          start ||= 0
          excerpt = source[start, window]

          digest = Digest::MD5.hexdigest(source)
          stamped = Enliterator::Audit.where(claim_id: claim.id).order(:created_at)
                                      .pick(:source_digest)
          {
            claim: { id: claim.id, key: claim.key, value: render_value(claim.value, cap: nil) },
            located: located,
            passage: excerpt,
            at_chars: start,
            source_chars: source.length,
            source_digest: digest,
            source_drifted: (stamped && stamped != digest) || nil,
            next: { provenance: "the claim's full chain" }
          }.compact
        end

        private

        # Exact value match first; else slide over the source finding the
        # window containing the most of the claim's distinctive tokens; a run
        # under RUN_MIN distinct tokens is not a location, it's a guess.
        def locate(source, value)
          idx = source.index(value)
          return [ true, [ idx - 80, 0 ].max ] if idx

          tokens = value.scan(/[A-Za-z0-9][A-Za-z0-9'-]{3,}/).uniq.first(24)
          return [ false, nil ] if tokens.size < RUN_MIN

          positions = tokens.filter_map { |t| source.index(/\b#{Regexp.escape(t)}\b/i) }
          return [ false, nil ] if positions.size < RUN_MIN

          # The densest cluster of token hits names the span.
          anchor = positions.sort.each_cons(RUN_MIN).min_by { |w| w.last - w.first }&.first
          anchor ? [ true, [ anchor - 80, 0 ].max ] : [ false, nil ]
        end
      end
    end
  end
end
