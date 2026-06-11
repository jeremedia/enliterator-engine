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

        def safe_type(type)
          return nil if type.blank?
          klass = type.to_s.safe_constantize
          unless Enliterator.tendable_type?(klass)
            raise ArgumentError, "unknown type #{type.inspect} — collection_overview lists the tended types"
          end
          klass.name
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
