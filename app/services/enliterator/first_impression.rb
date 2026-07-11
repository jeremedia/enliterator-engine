module Enliterator
  # v0.58 — the first-impression diagnostic. Measures how much a record's
  # ENLITERATION adds to a machine reader's first impression over the bare
  # surrogate a catalog gives it: coverage of source-absent facts, reliability
  # caution, calibration. Read-only, LLM-driven, invoked by rake — it adds no code
  # to any tending path, so with the rake never run behavior is byte-identical.
  #
  # The method mirrors the pilot (SPEC.md §v0.58): sample records in a context,
  # generate a grounded question set per record (keys grounded in the record's own
  # surrogate/claims — the model only phrases), answer the questions under each ARM
  # (no_map / map / manual / fulltext), blind-judge, and aggregate. `capability
  # moves inference, not contact`: the enliteration's value is largest exactly where
  # a stronger model cannot reach the missing knowledge on its own.
  module FirstImpression
    # Raised when the diagnostic is handed the Null adapter — a real LLM is
    # required; a silent no-op would fake a result (rule 3).
    class NullAdapterError < StandardError; end

    module_function

    # A forced-tool structured call with a graceful fallback. Prefers #decide (the
    # examiner/considerer substrate); if a tier's adapter cannot honor a forced tool
    # (returns blank), falls back to #converse + tolerant JSON parse. Raises on Null.
    def structured(llm, messages:, schema:, tool_name:, tags: [])
      raise NullAdapterError, "first_impression requires a real LLM adapter (got Null)" \
        if llm.nil? || llm.is_a?(Enliterator::Adapters::LLM::Null)

      result = llm.decide(messages: messages, schema: schema, tool_name: tool_name, tags: tags)
      return result if result.is_a?(Hash) && result.any?

      # Fallback: the adapter did not return structured output. Ask again in plain
      # JSON. (Some gateway-routed tiers don't support forced tool-calls.)
      text = llm.converse(
        messages: messages + [ { role: "user",
          content: "Respond with STRICT JSON ONLY, matching the schema. No prose outside the JSON." } ],
        tags: tags
      )
      parse_tolerant(text)
    end

    # Tolerant JSON extraction: strips code fences, grabs the outermost object, and
    # unwraps a double-encoded JSON string (the LiteLLM/bedrock quirk, v0.57.1).
    def parse_tolerant(text)
      s = text.to_s.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "")
      obj =
        begin
          JSON.parse(s)
        rescue JSON::ParserError
          m = s.match(/\{.*\}/m) or raise
          JSON.parse(m[0])
        end
      obj.is_a?(String) ? JSON.parse(obj) : obj
    end

    # ---- Orchestration ---------------------------------------------------

    # Run the diagnostic over a context. Samples `sample` records with live claims,
    # generates a grounded question set per record, answers it under each arm at each
    # tier (`reps` times), blind-judges, and returns a Report hash.
    #
    # @param context [Enliterator::Context, nil] nil = the whole collection (root)
    # @param llm     [#decide, nil] inject one adapter for ALL calls (tests); nil ⇒
    #   generator/judge resolve their config tiers and each tier answers on its own.
    def run(context: nil, sample: 5, tiers: nil, reps: 1, seed: 1, llm: nil, log: nil)
      tiers   = Array(tiers).map(&:to_s).reject(&:empty?)
      tiers   = default_tiers if tiers.empty?
      records = sample_records(context, sample, seed)
      log&.call("sampled #{records.size} record(s); #{tiers.size} tier(s) x #{reps} rep(s)")

      gen        = Generator.new(llm: llm)
      judge      = Judge.new(llm: llm)
      full_text  = Enliterator.configuration.first_impression_full_text

      runs = []
      records.each_with_index do |rec, i|
        claims = rec.enliterator_claims.live.to_a
        next if claims.empty?
        golden = gen.generate(rec, claims: claims)
        index  = golden.to_h { |q| [ q["id"].to_s, { "type" => q["type"].to_s, "deep" => !!q["deep"] } ] }
        arms   = Arms.build(rec, claims: claims, full_text: full_text&.call(rec))
        log&.call("record #{i + 1}/#{records.size}: #{golden.size} questions, #{arms.size} arms")

        arms.each do |arm_name, block|
          tiers.each do |tier|
            reps.times do
              ans = answer(llm || Enliterator.llm(tier: tier), block, golden)
              verdict = judge.judge(
                golden: golden,
                answers: ans[:answers].transform_values { |a| a["answer"] },
                first_expression: ans[:first_expression]
              )
              runs << Report::Run.new(
                arm: arm_name, tier: tier, record: record_key(rec), golden: index,
                confidences: ans[:answers].transform_values { |a| a["confidence"] },
                verdicts: verdict["verdicts"], fe_rich: verdict["fe_rich"], tokens: ans[:tokens]
              )
            end
          end
        end
      end
      Report.build(runs)
    end

    # Sample N records with live understanding-claims in the context, deterministically
    # by seed. Reuses the Catalog membership idiom: root membership is implicit
    # (context nil ⇒ all), named sub-contexts are explicit rows.
    def sample_records(context, n, seed)
      scope = Enliterator::Claim.live.understanding
      if context
        scope = scope.where(context_id: context.scope_ids).where(
          Enliterator::ContextMembership.member_exists(
            context,
            type_sql: "enliterator_claims.tendable_type",
            id_sql:   "enliterator_claims.tendable_id"
          ).arel.exists
        )
      end
      pairs = scope.distinct.pluck(:tendable_type, :tendable_id)
                   .shuffle(random: Random.new(seed)).first(n)
      pairs.group_by(&:first).flat_map do |type, group|
        klass = type.safe_constantize
        klass ? klass.where(id: group.map(&:last)).to_a : []
      end
    end

    def default_tiers
      ladder = Enliterator.staffing&.ladder
      Array(ladder).any? ? Array(ladder) : [ "quality" ]
    end

    def record_key(rec)
      "#{rec.class.name}/#{rec.id}"
    end

    # One arm's answers: the model reads the arm's context and answers the questions
    # with a stated confidence. `tokens` is an input-size proxy (chars/4) — the
    # relative arm sizes (the compression story), not a billed count.
    ANSWER_SCHEMA = {
      "type" => "object",
      "properties" => {
        "first_expression" => { "type" => "string" },
        "answers" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "id"         => { "type" => "string" },
              "answer"     => { "type" => "string" },
              "confidence" => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0 }
            },
            "required" => %w[id answer confidence]
          }
        }
      },
      "required" => %w[answers]
    }.freeze

    ANSWER_SYSTEM = <<~SYS.strip
      You are helping a reader understand a source and answer questions about it. FIRST write a
      'first_expression': 2-4 sentences on what this resource is, what it claims, and what stands
      out. THEN answer each question from the PROVIDED SOURCE ONLY, with an honest 'confidence'
      (0..1) that your answer is correct. If the source does not contain the information, say it is
      not in the source rather than guessing.
    SYS

    def answer(llm, context_block, golden)
      q_lines = golden.map { |q| "Q #{q['id']}: #{q['question']}" }.join("\n")
      result = structured(
        llm,
        messages: [ { role: "system", content: ANSWER_SYSTEM },
                    { role: "user", content: "SOURCE:\n#{context_block}\n\nQUESTIONS:\n#{q_lines}" } ],
        schema: ANSWER_SCHEMA, tool_name: "emit_answers", tags: [ "enliterator", "first-impression-answer" ]
      )
      answers = Array(result["answers"] || result[:answers]).each_with_object({}) do |a, h|
        a = a.transform_keys(&:to_s)
        h[a["id"].to_s] = { "answer" => a["answer"].to_s, "confidence" => a["confidence"].to_f }
      end
      { first_expression: (result["first_expression"] || result[:first_expression]).to_s,
        answers: answers, tokens: (context_block.to_s.length / 4.0).round }
    end
  end
end
