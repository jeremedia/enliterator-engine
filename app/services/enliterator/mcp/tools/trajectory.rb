module Enliterator
  module Mcp
    module Tools
      # How understanding COMPOUNDED — per facet, visit by visit: what was
      # added, revised, kept; the deepening made queryable. This is the tool
      # no plain RAG system can offer: "the collection initially read this as
      # X; after reading the whole work it revised to Y."
      class Trajectory < Tool
        STEPS_CAP = 8
        DIFF_CAP  = 200

        name_and_description "trajectory",
          "A record's understanding over time: per facet, each visit's operations " \
          "(added/updated/kept) and what changed, including deep-read supersessions. " \
          "Use to narrate how the collection LEARNED about a record."

        schema({
          "type"    => str("Record type"),
          "id"      => str("Record id"),
          "facet"   => str("Optional facet to focus on"),
          "context" => str("Optional context key")
        }, required: [ :type, :id ])

        def call(type:, id:, facet: nil, context: nil)
          ctx    = resolve_context(context)
          record = find_record!(type, id)
          lines  = Enliterator::Trajectory.for(record, facet: facet.presence,
                                               context: ctx, last: STEPS_CAP)

          {
            type: type, id: id.to_s, label: label_for(record),
            facets: lines.map { |line|
              {
                facet: line[:facet],
                steps: line[:steps].map { |s| step_card(s) }
              }
            },
            next: { provenance: "any claim's full chain", quote: "the source behind a claim" }
          }
        end

        private

        def step_card(step)
          visit = step[:visit]
          {
            visit_id:   visit.id,
            at:         visit.created_at,
            tier:       visit.tier,
            reason:     visit.reason,
            ops:        step[:ops],
            confidence: step[:confidence],
            changes: Array(step[:diff]).map { |d|
              { key: d[:key], kind: d[:kind],
                from: d[:from] && render_value(d[:from], cap: DIFF_CAP),
                to:   d[:to] && render_value(d[:to], cap: DIFF_CAP) }.compact
            }
          }.compact
        end
      end
    end
  end
end
