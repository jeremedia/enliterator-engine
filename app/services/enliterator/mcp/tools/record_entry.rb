module Enliterator
  module Mcp
    module Tools
      # THE core tool: one record's full finding-aid entry — every live claim
      # WITH ITS PROVENANCE ON ITS SLEEVE (confidence, tier, status, locked,
      # attribution, latest audit verdict), the tending rollup, contexts,
      # measures, and the analytical entries (parts) when the record has been
      # deep-read. Works identically for a Part (an analytical entry has an
      # entry too).
      class RecordEntry < Tool
        CLAIMS_CAP = 60
        PARTS_CAP  = 80

        name_and_description "record_entry",
          "One record's full entry: live claims grouped by facet, each with provenance " \
          "(confidence, tier, audit verdict, locked, attribution), tending history rollup, " \
          "contexts, and per-section analytical entries when deep-read. Cite claims from " \
          "here; drill with provenance(claim_id), quote(claim_id), trajectory."

        schema({
          "type"    => str("Record type (e.g. DocMetum, Enliterator::Part)"),
          "id"      => str("Record id"),
          "context" => str("Optional context key — claims read cumulatively up its path")
        }, required: [ :type, :id ])

        def call(type:, id:, context: nil)
          ctx    = resolve_context(context)
          record = find_record!(type, id)

          claims = record.enliterator_claims.live.includes(:context).order(:key)
          claims = claims.where(context_id: ctx.scope_ids) if ctx
          claims = claims.to_a
          verdicts = latest_verdicts(claims)

          visits = record.enliterator_visits.where(status: "succeeded", applied: true)

          {
            type: type, id: id.to_s,
            label:    label_for(record),
            entry:    entry_path(type, id),
            contexts: record.enliterator_contexts.order(:name).pluck(:key),
            claims:   claims_by_facet(claims.first(CLAIMS_CAP), verdicts),
            claims_truncated: claims.size > CLAIMS_CAP || nil,
            tending: {
              visits:    visits.count,
              last_at:   visits.maximum(:created_at),
              facets:    visits.distinct.pluck(:facet).sort
            },
            measures: record.enliterator_measures.each_with_object({}) { |m, h| h[m.name] = m.score },
            parts:    parts_for(record),
            next: {
              provenance: "how any claim is known (claim id)",
              quote:      "the source passage behind a claim (claim id)",
              trajectory: "how this understanding evolved",
              connections: "what this record links to"
            }
          }.compact
        end

        private

        # Group by the facet of the claim's minting visit (claims don't carry
        # facet; their visits do). Host-seeded claims (no visit) group under
        # "asserted".
        def claims_by_facet(claims, verdicts)
          visit_facets = Enliterator::Visit.where(id: claims.filter_map(&:visit_id))
                                           .pluck(:id, :facet).to_h
          claims.group_by { |c| visit_facets[c.visit_id] || "asserted" }
                .transform_values { |cs| cs.map { |c| claim_card(c, verdict: verdicts[c.id]) } }
        end

        # Latest verdict per claim for DISPLAY: human > examiner > agent (an
        # agent flag never outranks the instrument, but its presence shows).
        RANK = { "human" => 3, "examiner" => 2, "agent" => 1 }.freeze
        def latest_verdicts(claims)
          best = {}
          Enliterator::Audit.where(claim_id: claims.map(&:id)).order(:created_at).each do |a|
            current = best[a.claim_id]
            next if current && RANK.fetch(current.source, 0) > RANK.fetch(a.source, 0)
            best[a.claim_id] = a
          end
          best.transform_values { |a| "#{a.source}:#{a.verdict}" }
        end

        def parts_for(record)
          parts = Enliterator::Part.where(record: record).order(:ordinal)
          return nil if parts.empty?
          counts = Enliterator::Claim.live
                     .where(tendable_type: "Enliterator::Part", tendable_id: parts.map(&:id))
                     .group(:tendable_id).count
          parts.first(PARTS_CAP).map do |p|
            { type: "Enliterator::Part", id: p.id, ordinal: p.ordinal,
              heading: p.title, claim_count: counts[p.id].to_i }
          end
        end
      end
    end
  end
end
