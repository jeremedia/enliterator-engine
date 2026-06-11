module Enliterator
  module Mcp
    module Tools
      # The subject-heading index — the controlled vocabulary in USE, with
      # counts congruent to their click-throughs (the v0.24 rule): every
      # [key, term, n] here returns exactly n records from subject_search.
      class BrowseSubjects < Tool
        name_and_description "browse_subjects",
          "The subject-heading browse index: which claim keys act as headings and their top " \
          "values with record counts. The structural answer to 'what does this collection " \
          "cover about X' — counts are exact, follow any heading with subject_search."

        schema({
          "context" => str("Optional context key (headings are membership-scoped)")
        })

        def call(context: nil)
          ctx      = resolve_context(context)
          overview = Enliterator::Catalog.new(context: ctx).overview
          {
            context: ctx&.key || "root",
            headings: overview[:headings].map { |h|
              { key: h[:key], approximate: h[:approx] || nil,
                values: h[:values] }.compact
            },
            next: { subject_search: "the records behind any heading (key + value)" }
          }
        end
      end
    end
  end
end
