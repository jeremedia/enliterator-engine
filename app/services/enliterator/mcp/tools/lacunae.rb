module Enliterator
  module Mcp
    module Tools
      # "What does this collection know it's missing?" — the open lacunae (the
      # known-unknowns: required terms that were looked for and not found),
      # rolled up by facet and diagnosis, with a bounded sample. The negative-space
      # companion to collection_overview's self-portrait. Empty when the host has
      # not adopted lacunae (config.record_lacunae off) or has no open gaps.
      class Lacunae < Tool
        SAMPLE_CAP = 25

        name_and_description "lacunae",
          "The collection's known gaps: open lacunae — required terms tending looked for " \
          "and could not find — rolled up by facet and diagnosis, with a sample. Pass a " \
          "context key to scope to one collection (omit for the whole tree). Read this to " \
          "report what the collection knows it is missing, distinct from what it has asserted."

        schema({ "context" => str("collection context key to scope to (omit for all)") })

        def call(context: nil)
          ctx   = resolve_context(context)
          scope = Enliterator::Lacuna.open
          scope = scope.where(context_id: ctx.id) if ctx

          total = scope.count
          {
            open_total:    total,
            by_facet:      scope.group(:facet).count,
            by_diagnosis:  scope.group(:diagnosis).count,
            sample:        scope.includes(:tendable).order(detections: :desc, id: :desc)
                                .limit(SAMPLE_CAP).map { |l| card(l) },
            sample_capped: total > SAMPLE_CAP,
            next: {
              record_entry:        "inspect a record a lacuna names (type + id from the sample)",
              collection_overview: "the collection's current state (what it HAS asserted)",
              human_view:          "/enliterator/status"
            }
          }
        end

        private

        def card(lac)
          rec = lac.tendable
          {
            type:             lac.tendable_type,
            id:               lac.tendable_id,
            label:            (rec ? label_for(rec) : "#{lac.tendable_type} ##{lac.tendable_id}"),
            facet:            lac.facet,
            key:              lac.key,
            diagnosis:        lac.diagnosis,
            note:             lac.note,
            detections:       lac.detections,
            last_detected_at: lac.last_detected_at&.iso8601
          }
        end
      end
    end
  end
end
