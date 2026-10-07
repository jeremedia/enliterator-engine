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

        honors_member_scope!   # v0.83

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
          # Resolve the primary embedding ONCE — both the neighbor query and the
          # degraded-state label key off it (avoids a duplicate find_by per call).
          own_embedding = record.enliterator_embeddings.find_by(kind: "primary")

          edges = atlas[:edges].select { |e| e[:s] == node_id || e[:t] == node_id }
                               .reject { |e| e[:key] == "in-context" }
          # v0.83: the Atlas is built over the whole collection (cached); under
          # an audience scope an edge to or from a record this reader may not
          # see does not exist. Entity edges out of this record are its own
          # claims and stay.
          edges = visible_edges(edges, node_id) if Enliterator::MemberScope.active?
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
            neighbors: neighbors_for(record, ctx, own_embedding),
            neighbors_state: neighbors_state(own_embedding),
            next: { record_entry: "any resolved target's full entry" }
          }.compact
        end

        private

        # One query per record type among the endpoints, not one per edge.
        def visible_edges(edges, node_id)
          others = edges.map { |e| e[:s] == node_id ? e[:t] : e[:s] }.select { |n| n.start_with?("r:") }
          by_type = others.map { |n| n.split(":", 3).drop(1) }.group_by(&:first)
                          .transform_values { |pairs| pairs.map(&:last) }
          visible = by_type.flat_map do |type, ids|
            Enliterator::MemberScope.current.filter_map { |rel| rel if rel.klass.name == type }.flat_map do |rel|
              pk = rel.klass.primary_key
              rel.where(pk => ids).pluck(pk).map { |id| "r:#{type}:#{id}" }
            end
          end.to_set
          edges.select do |e|
            other = e[:s] == node_id ? e[:t] : e[:s]
            !other.start_with?("r:") || visible.include?(other)
          end
        end

        def target_ref(node_id, labels)
          if node_id.start_with?("r:")
            _, type, id = node_id.split(":", 3)
            { kind: "record", type: type, id: id, label: labels[node_id] }
          else
            { kind: "entity", label: labels[node_id] || node_id.delete_prefix("e:") }
          end
        end

        def neighbors_for(record, ctx, own = nil)
          own ||= record.enliterator_embeddings.find_by(kind: "primary")
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

        def neighbors_state(own)
          return "no_embedding" if own&.embedding.nil?
          "ok"
        end
      end
    end
  end
end
