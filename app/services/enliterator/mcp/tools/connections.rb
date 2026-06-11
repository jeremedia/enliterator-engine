module Enliterator
  module Mcp
    module Tools
      # What a record links TO: the typed, provenanced edges from the cached
      # Atlas build (resolved record→record links and named entities — never
      # a fresh graph assembly, the v0.20 law) plus semantic neighbors from
      # the retrieval pool.
      class Connections < Tool
        EDGES_CAP    = 40
        NEIGHBOR_CAP = 8

        name_and_description "connections",
          "A record's connections: typed claim edges (advisor, supersedes, cited works — " \
          "each with confidence and any audit verdict) and nearest semantic neighbors. " \
          "The Atlas, queryable."

        schema({
          "type"    => str("Record type"),
          "id"      => str("Record id"),
          "context" => str("Optional context key")
        }, required: [ :type, :id ])

        def call(type:, id:, context: nil)
          ctx    = resolve_context(context)
          record = find_record!(type, id)
          atlas  = Enliterator::Atlas.build(context: ctx)
          node_id = "r:#{type}:#{id}"
          labels  = atlas[:nodes].each_with_object({}) { |n, h| h[n[:id]] = n[:label] }

          edges = atlas[:edges].select { |e| e[:s] == node_id || e[:t] == node_id }
                               .reject { |e| e[:key] == "in-context" }
          {
            type: type, id: id.to_s, label: label_for(record),
            context: ctx&.key || "root",
            edges: edges.first(EDGES_CAP).map { |e|
              other = e[:s] == node_id ? e[:t] : e[:s]
              { key: e[:key],
                direction: e[:s] == node_id ? "out" : "in",
                target: target_ref(other, labels),
                weight: e[:w], verdict: e[:verdict] }.compact
            },
            edges_truncated: edges.size > EDGES_CAP || nil,
            neighbors: neighbors_for(record, ctx),
            next: { record_entry: "any resolved target's full entry" }
          }.compact
        end

        private

        def target_ref(node_id, labels)
          if node_id.start_with?("r:")
            _, type, id = node_id.split(":", 3)
            { kind: "record", type: type, id: id, label: labels[node_id] }
          else
            { kind: "entity", label: labels[node_id] || node_id.delete_prefix("e:") }
          end
        end

        def neighbors_for(record, ctx)
          own = record.enliterator_embeddings.find_by(kind: "primary")
          return [] if own&.embedding.nil?
          Enliterator::Embedding.where(kind: "primary").in_context(ctx)
                                .where.not(id: own.id)
                                .nearest_neighbors(:embedding, own.embedding, distance: "cosine")
                                .first(NEIGHBOR_CAP).filter_map do |e|
            rec = e.embeddable
            next if rec.nil?
            { type: e.embeddable_type, id: e.embeddable_id,
              label: label_for(rec), distance: e.neighbor_distance&.round(4) }
          end
        end
      end
    end
  end
end
