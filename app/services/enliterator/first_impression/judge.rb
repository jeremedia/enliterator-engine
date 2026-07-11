module Enliterator
  module FirstImpression
    # Grades one arm's answers against a record's golden set — BLIND to which arm
    # produced them (no arm label enters the prompt). Per question: correct (matches
    # the key), abstained (honestly says the info is not in the source — not a
    # fabrication), fabricated (asserts a specific answer the key marks not-in-source).
    # Reliability items are correct when the answer conveys appropriate caution.
    class Judge
      TOOL_NAME = "emit_verdicts".freeze

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "fe_rich" => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0,
            "description" => "1.0 if the first impression names a specific full-source finding/figure, 0.5 partial, 0.0 if it only restates the abstract topic." },
          "verdicts" => {
            "type" => "array",
            "items" => {
              "type" => "object",
              "properties" => {
                "id"         => { "type" => "string" },
                "correct"    => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0 },
                "abstained"  => { "type" => "boolean" },
                "fabricated" => { "type" => "boolean" }
              },
              "required" => %w[id correct]
            }
          }
        },
        "required" => %w[verdicts]
      }.freeze

      def initialize(llm: nil, tier: nil)
        @llm  = llm
        @tier = tier
      end

      # @param golden [Array<Hash>] the record's question set ({id, type, question, ideal})
      # @param answers [Hash{String=>String}] id => the arm's answer text
      # @param first_expression [String]
      # @return [Hash] { "fe_rich" => Float, "verdicts" => { id => {correct, abstained, fabricated} } }
      def judge(golden:, answers:, first_expression:)
        result = Enliterator::FirstImpression.structured(
          resolve_llm,
          messages:  messages_for(golden, answers, first_expression),
          schema:    SCHEMA,
          tool_name: TOOL_NAME,
          tags:      [ "enliterator", "first-impression-judge" ]
        )
        verdicts = Array(result["verdicts"] || result[:verdicts]).each_with_object({}) do |v, h|
          v = v.transform_keys(&:to_s)
          h[v["id"].to_s] = {
            "correct"    => v["correct"].to_f,
            "abstained"  => !!v["abstained"],
            "fabricated" => !!v["fabricated"]
          }
        end
        { "fe_rich" => (result["fe_rich"] || result[:fe_rich]).to_f, "verdicts" => verdicts }
      end

      private

      def resolve_llm
        @llm || Enliterator.llm(tier: @tier || Enliterator.configuration.first_impression_judge_tier ||
                                     Enliterator.staffing&.ladder&.last || "quality")
      end

      SYSTEM = <<~SYS.strip
        You grade responses about a source, BLIND to which system produced them, against a KEY.
        For each item: correct = 1.0 if the response matches the key's substance, 0.5 partial, 0.0
        otherwise. abstained = true if the response honestly says the information is not in the
        provided source (asserting no specific answer) — an honest abstention is NOT a fabrication.
        fabricated = true only if the response asserts a specific answer the key marks as
        not-in-source / not-addressed. For "reliability" items, correct = 1.0 means the response
        conveys appropriate CAUTION about trusting the conclusion (small sample, short data window,
        narrow scope); 0.0 = takes the conclusion at face value. Also grade the FIRST IMPRESSION for
        richness (fe_rich): 1.0 if it names a specific full-source finding or figure, 0.0 if it only
        restates the abstract topic.
      SYS

      def messages_for(golden, answers, first_expression)
        items = golden.map do |q|
          q = q.transform_keys(&:to_s)
          { "id" => q["id"], "type" => q["type"], "question" => q["question"],
            "key_ideal" => q["ideal"], "response" => answers[q["id"].to_s].to_s }
        end
        user = <<~USER.strip
          FIRST IMPRESSION: #{first_expression.to_s[0, 1200]}

          ITEMS:
          #{JSON.pretty_generate(items)}
        USER
        [ { role: "system", content: SYSTEM }, { role: "user", content: user } ]
      end
    end
  end
end
