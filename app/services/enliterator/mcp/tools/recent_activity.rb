module Enliterator
  module Mcp
    module Tools
      # The morning question — "how did last night's tending go?" — as one
      # call. A time-windowed digest of the collection's own activity: cycles,
      # work, failures WITH their errors, deep-read sessions, governance
      # motion. Where collection_overview is the self-portrait (state),
      # recent_activity is the diary (change).
      class RecentActivity < Tool
        MAX_HOURS = 168   # a week — past that you want Report.summary, not a diary

        name_and_description "recent_activity",
          "What happened to the collection lately: heartbeat cycles, visits by facet/tier/" \
          "reason, failures with their recorded errors, deep-read sessions, and governance " \
          "motion (suggestions filed, terms moved, audit flags). Default window 12 hours, " \
          "max 168. Read this before reporting on the collection's recent behavior."

        schema({ "hours" => int("window in hours (1-#{MAX_HOURS}, default 12)") })

        def call(hours: nil)
          h = (hours || 12).to_i.clamp(1, MAX_HOURS)
          Enliterator::Brief.report(since: h.hours).merge(
            next: {
              collection_overview: "the collection's current state (stats, condition, accuracy)",
              record_entry:        "inspect any record a failure or reading named",
              human_view:          "/enliterator/heartbeat"
            }
          )
        end
      end
    end
  end
end
