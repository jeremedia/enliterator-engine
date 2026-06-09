module Enliterator
  module Trajectory
    # The SEMANTIC check on compounding — a blind pairwise comparison of a
    # record's understanding at two visits, via the same forced-tool `#decide`
    # plumbing the considerer uses. The churn heuristic (string similarity) says
    # whether an UPDATE changed the words; the judge says whether the later
    # state is actually BETTER. They cross-validate.
    #
    # BLINDING IS MANDATORY: the two states are presented as A/B in randomized
    # order with no "before/after" language anywhere in the prompt; the
    # de-blinding map stays local. Position bias is the classic failure of
    # LLM-judge designs — this is the guard.
    #
    #   Judge.new.judge!(record, facet: "summary", early: v1, late: v5)
    #   # => { later_wins: true, richer: :later, more_accurate: :tie,
    #   #      rationale: "...", confidence: 0.85 }  (nil when the LLM is Null)
    class Judge
      TOOL_NAME = "compare_states".freeze
      SNIPPET   = 600

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "winner"        => { "type" => "string", "enum" => %w[A B tie],
                               "description" => "Which state is the more useful understanding overall." },
          "richer"        => { "type" => "string", "enum" => %w[A B tie],
                               "description" => "Which covers more of what matters in the document." },
          "more_accurate" => { "type" => "string", "enum" => %w[A B tie],
                               "description" => "Which is more faithful to the document text." },
          "rationale"     => { "type" => "string" },
          "confidence"    => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0 }
        },
        "required" => %w[winner richer more_accurate rationale confidence]
      }.freeze

      def initialize(llm: nil, tier: nil, rng: Random.new)
        @llm  = llm
        @tier = tier
        @rng  = rng
      end

      # Compare the record's claim-state at two visits (or times), blind.
      # Returns the de-blinded verdict, or nil when the adapter is Null (soft
      # degrade, mirrors Conversation — judging writes nothing, so no raise).
      def judge!(record, facet:, early:, late:, context: nil)
        adapter = resolve_llm
        return nil if adapter.is_a?(Enliterator::Adapters::LLM::Null)

        early_state = facet_state(record, early, facet, context)
        late_state  = facet_state(record, late, facet, context)
        return nil if early_state.empty? && late_state.empty?

        # The blind: late is "A" on a coin flip; map back after.
        late_is_a = @rng.rand < 0.5
        a, b = late_is_a ? [ late_state, early_state ] : [ early_state, late_state ]

        result = adapter.decide(
          messages:  messages_for(record, facet, a, b),
          schema:    SCHEMA,
          tool_name: TOOL_NAME,
          tags:      [ "enliterator", "trajectory-judge" ]
        )
        deblind(result, late_is_a)
      end

      private

      def resolve_llm
        return @llm if @llm
        tier = @tier || Enliterator.configuration.considerer_tier ||
               Enliterator.staffing.ladder.last || "quality"
        Enliterator.llm(tier: tier)
      end

      def facet_state(record, visit_or_time, facet, context)
        facet_visit_ids = record.enliterator_visits.where(facet: facet).pluck(:id).to_set
        Enliterator::Trajectory.state_at(record, visit_or_time, context: context)
          .select { |c| c.visit_id && facet_visit_ids.include?(c.visit_id) }
          .sort_by(&:key)
      end

      # `later` per dimension: :later / :earlier / :tie, given which label held it.
      def deblind(result, late_is_a)
        return nil unless result.respond_to?(:[])
        map = ->(label) {
          case label.to_s
          when "tie" then :tie
          when "A"   then late_is_a ? :later : :earlier
          when "B"   then late_is_a ? :earlier : :later
          end
        }
        winner = map.call(result["winner"] || result[:winner])
        return nil if winner.nil?
        {
          later_wins:    winner == :later ? true : (winner == :tie ? nil : false),
          winner:        winner,
          richer:        map.call(result["richer"]        || result[:richer]),
          more_accurate: map.call(result["more_accurate"] || result[:more_accurate]),
          rationale:     (result["rationale"]  || result[:rationale]).to_s,
          confidence:    (result["confidence"] || result[:confidence]).to_f
        }
      end

      def messages_for(record, facet, a_state, b_state)
        [
          { role: "system", content: <<~SYS.strip },
            You evaluate two CANDIDATE UNDERSTANDINGS of the same document — two sets of
            claims labeled A and B. Decide which is the more useful understanding overall
            (winner), which covers more of what matters (richer), and which is more
            faithful to the document (more_accurate) — A, B, or tie for each. Judge ONLY
            against the document text provided. The labels A and B are arbitrary and
            carry no meaning; assume nothing about where either candidate came from.
            Be willing to call a tie when the difference is cosmetic.
          SYS
          { role: "user", content: <<~USER.strip }
            DOCUMENT (snippet):
            #{record.enliterator_text(facet: facet).to_s.gsub(/\s+/, ' ')[0, SNIPPET]}

            CANDIDATE A (claims about the "#{facet}" facet):
            #{render_state(a_state)}

            CANDIDATE B (claims about the "#{facet}" facet):
            #{render_state(b_state)}
          USER
        ]
      end

      def render_state(claims)
        return "(no claims)" if claims.empty?
        claims.map { |c| "- #{c.key}: #{Enliterator::Trajectory.render(c.value)}" }.join("\n")
      end
    end
  end
end
