module Enliterator
  module Mcp
    module Tools
      # The self-portrait in one call — what an agent reads FIRST, every
      # session: what this collection is, how much of it is enliterated, what
      # facets it speaks, what condition it's in, and how accurate its claim
      # store has measured. All cached rollups (the v0.20 idiom) — this tool
      # is cheap to call.
      class CollectionOverview < Tool
        FACETS_CAP = 20

        name_and_description "collection_overview",
          "Orient yourself: the collection's self-portrait — holdings counts, context tree, " \
          "facets with tended counts, conservation summary, and audited accuracy. Call this " \
          "first; everything else cites types, contexts, and facets it names."

        schema({
          "context" => str("Optional context key to scope the portrait (see the context tree this returns)")
        })

        def call(context: nil)
          ctx      = resolve_context(context)
          overview = Enliterator::Catalog.new(context: ctx).overview
          synopsis = Enliterator::Synopsis.build(context: ctx)
          condition = Enliterator::Condition.report

          {
            # v0.57: the charter LEADS — the collection says what it IS before
            # what it counts. Key ABSENT when the host declares no collection
            # tendable (spec-pinned; the pre-charter payload is byte-identical).
            **charter_block,
            context: ctx&.key || "root",
            stats:   overview[:stats],
            types:   overview[:types],
            contexts: context_tree,
            facets: Array(synopsis[:facets]).first(FACETS_CAP).map { |f|
              { facet: f[:facet], tier: f[:tier], tended_count: f[:tended_count],
                terms: Array(f[:vocabulary]).map { |v| v[:key] } }
            },
            condition: condition.slice(:surveyed, :total, :untendable, :residue_count)
                                .merge(piles: Array(condition[:piles]).map { |p| p.slice(:signature, :count, :band) }),
            accuracy: Enliterator::Audit.accuracy_cached.map { |r|
              r.slice(:facet, :tier, :audited, :supported_rate, :contradicted)
            },
            next: {
              vocabulary:      "term meanings per facet",
              search:          "find records by meaning",
              browse_subjects: "the subject-heading index",
              human_view:      "/enliterator/status"
            }
          }
        end

        private

        # The told identity + its derived operational values, with a next: hint
        # to the collection record's own entry. {} when unconfigured/unseeded.
        def charter_block
          c = Enliterator::Charter.read
          return {} if c.nil?

          {
            charter: {
              **c[:told],
              untold:  c[:untold],
              derived: c[:derived],
              record_entry_hint: "record_entry type=#{c[:record][:type]} id=#{c[:record][:id]} — the collection's own entry"
            }
          }
        end

        def context_tree
          Enliterator::Context.order(:id).map do |c|
            { key: c.key, name: c.name, parent: c.parent&.key,
              members: c.memberships.count }
          end
        end
      end
    end
  end
end
