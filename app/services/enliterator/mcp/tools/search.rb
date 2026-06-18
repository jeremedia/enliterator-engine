module Enliterator
  module Mcp
    module Tools
      # Search by meaning — the same embedding pool Chat retrieval and the
      # Catalog read, so counts and reach agree everywhere. Cards carry the
      # UNDERSTANDING (excerpt, claim count, tending depth), not bare ids.
      class Search < Tool
        LIMIT_MAX = 10

        name_and_description "search",
          "Semantic search over the enliterated holdings. Returns the nearest records " \
          "with their understanding (excerpt, claim count, tending depth, cosine distance). " \
          "Follow up with record_entry for any result."

        schema({
          "q"       => str("The query — a theme, question, or subject, in natural language"),
          "context" => str("Optional context key to scope the pool to members"),
          "type"    => str("Optional record type filter (collection_overview lists types)"),
          "limit"   => int("Max results (default 5, cap #{LIMIT_MAX})")
        }, required: [ :q ])

        def call(q:, context: nil, type: nil, limit: 5)
          ctx     = resolve_context(context)
          catalog = Enliterator::Catalog.new(context: ctx, type: safe_type(type))
          result  = catalog.search(q.to_s)

          if result[:degraded]
            raise "semantic search is unavailable (#{result[:degraded]}): the embedder is not " \
                  "configured or returned nothing — browse_subjects and subject_search still work"
          end

          cards = result[:records].first(limit.clamp(1, LIMIT_MAX))
          {
            query:   q,
            context: ctx&.key || "root",
            records: cards.map { |c| search_card(c) },
            next: { record_entry: "the full entry for any result (type + id)" }
          }
        end

        private

        # The OPTIONAL type filter. A reader model often guesses a domain-natural
        # value ("thesis"/"theses") that is NOT a tended Ruby class — and an
        # unrecognized OPTIONAL filter must never fail the whole search (doing so
        # surfaced to the patron as a fake "search temporarily unavailable", since
        # the loop hands the model only a generic floor, not this detail, so it
        # can't self-correct). Drop the bad filter and search UNFILTERED; log why
        # (rule 3). Contrast find_record! (tool.rb), whose `type` is REQUIRED and is
        # already a real class name carried from a prior result — that one still raises.
        def safe_type(type)
          return nil if type.blank?
          klass = type.to_s.safe_constantize
          return klass.name if Enliterator.tendable_type?(klass)

          Enliterator.logger&.info(
            "[enliterator] search: ignoring unknown type filter #{type.inspect} " \
            "(not a tended type) — searching unfiltered")
          nil
        end

        def search_card(c)
          { type: c[:type], id: c[:id], label: c[:label],
            excerpt: c[:excerpt], claim_count: c[:claim_count],
            visit_count: c[:visit_count],
            distance: c[:distance]&.round(4),
            entry: entry_path(c[:type], c[:id]) }.compact
        end
      end
    end
  end
end
