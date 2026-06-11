module Enliterator
  module Mcp
    module Tools
      # The agent as PATRON of authority control: file a vocabulary
      # suggestion exactly the way the tending model does — into the pending
      # queue, where pressure accumulates, the considerer weighs it, and a
      # curator ratifies. Never a direct vocabulary write.
      class ProposeTerm < Tool
        name_and_description "propose_term",
          "Propose a new vocabulary term through authority control. Requires the record " \
          "that prompted it (proposals arise from reading something). The suggestion " \
          "joins the pending queue — it is NOT applied until a curator acts."

        schema({
          "type"      => str("The record type that prompted this proposal"),
          "id"        => str("The record id"),
          "facet"     => str("The facet the term belongs to (see vocabulary)"),
          "key"       => str("The proposed term key (snake_case)"),
          "rationale" => str("Why the vocabulary needs this term"),
          "example"   => str("Optional example value this term would hold"),
          "context"   => str("Optional context key the proposal is scoped to")
        }, required: [ :type, :id, :facet, :key, :rationale ])

        def call(type:, id:, facet:, key:, rationale:, example: nil, context: nil)
          ctx    = resolve_context(context)
          record = find_record!(type, id)

          suggestion = Enliterator::Suggestion.create!(
            tendable:      record,
            facet:         facet.to_s,
            proposed_key:  key.to_s.strip,
            rationale:     "mcp-agent: #{rationale}",
            example_value: example,
            status:        "pending",
            context:       ctx
          )
          Enliterator::ProposedTerm.refresh!

          pressure = Enliterator::ProposedTerm.find_by(proposed_key: suggestion.proposed_key)
          {
            filed:        true,
            suggestion_id: suggestion.id,
            proposed_key: suggestion.proposed_key,
            status:       "pending — awaiting the considerer and a curator",
            pressure:     pressure&.pressure,
            distinct_records: pressure&.distinct_records,
            next: { human_view: "/enliterator/suggestions" }
          }.compact
        end
      end
    end
  end
end
