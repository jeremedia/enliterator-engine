module Enliterator
  module Mcp
    module Tools
      # A heading's click-through: the records holding a live understanding
      # claim key=value. Same scope and shapes as browse_subjects' tally —
      # the count on the heading equals the total here, guaranteed.
      class SubjectSearch < Tool
        name_and_description "subject_search",
          "Records holding a live claim key=value (a subject heading's records). " \
          "Values are byte-exact — use exactly what browse_subjects returned."

        schema({
          "key"     => str("The claim key (e.g. advisor, keywords, index_terms)"),
          "value"   => str("The exact value, byte-for-byte as browse_subjects returned it"),
          "context" => str("Optional context key"),
          "page"    => int("Page number (default 1)")
        }, required: [ :key, :value ])

        def call(key:, value:, context: nil, page: 1)
          ctx    = resolve_context(context)
          result = Enliterator::Catalog.new(context: ctx).subject(key.to_s, value.to_s, page: page)
          {
            key: key, value: value, context: ctx&.key || "root",
            total: result[:total], page: result[:page], pages: result[:pages],
            records: result[:records].map { |c|
              { type: c[:type], id: c[:id], label: c[:label], excerpt: c[:excerpt],
                entry: entry_path(c[:type], c[:id]) }
            },
            next: { record_entry: "the full entry for any result" }
          }
        end
      end
    end
  end
end
