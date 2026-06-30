module Enliterator
  # The considerer — the tending loop turned on the VOCABULARY itself.
  #
  # 178 proposed keys is more than a person can curate row-by-row, but cross-cutting
  # synthesis over the whole field is exactly what an LLM is good at. The considerer
  # reads all open proposed terms together (with their accumulated PRESSURE and
  # resurgence), decides each — map onto an existing key, approve as a new one, or
  # reject — then AUTO-APPLIES the reversible verdicts (maps + confident rejects) and
  # HOLDS approves (which change the contract) for human ratification. The curator
  # flips from judge-of-178 to ratifier-of-a-slate.
  #
  #   Enliterator::Considerer.new.consider!
  #   # => { considered: 178, auto_mapped: 41, auto_rejected: 22, approves_recommended: 6, held: 9 }
  class Considerer
    TOOL_NAME = "recommend_vocabulary".freeze

    RECOMMENDATION_SCHEMA = {
      "type" => "object",
      "properties" => {
        "recommendations" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "proposed_key"   => { "type" => "string" },
              "decision"       => { "type" => "string", "enum" => %w[map approve reject] },
              "map_to"         => { "type" => "string", "description" => "an EXACT existing canonical key (decision=map)" },
              "canonical_name" => { "type" => "string", "description" => "a clean name for the new key (decision=approve)" },
              "rationale"      => { "type" => "string" },
              "confidence"     => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0 }
            },
            "required" => %w[proposed_key decision rationale confidence]
          }
        }
      },
      "required" => %w[recommendations]
    }.freeze

    def initialize(llm: nil, autonomy: nil, min_confidence: nil, context: nil)
      @llm            = llm
      @autonomy       = (autonomy || Enliterator.configuration.considerer_autonomy || :auto_safe).to_sym
      @min_confidence = (min_confidence || Enliterator.configuration.considerer_min_confidence || 0.75).to_f
      # v0.13: consider ONE context's open field (its verdicts write to it,
      # rule 4). nil = the root scope — the entire pre-v0.13 universe.
      @context        = context
    end

    # Refresh pressure, ask the agent over the current scope's open field in
    # batches, apply per autonomy. Returns aggregate summary counts.
    #
    # Accepts an optional block that is yielded after each batch completes:
    #   consider! { |done, total| ... }
    # No-block callers are byte-identical in behavior.
    def consider!(&block)
      Enliterator::ProposedTerm.refresh!
      terms = scoped_terms
      return empty_summary if terms.empty?

      canonical   = canonical_keys
      batch_size  = Enliterator.configuration.considerer_batch_size
      aggregate   = empty_summary
      done        = 0

      terms.each_slice(batch_size) do |slice|
        result = adapter.decide(
          messages:  messages_for(slice, canonical),
          schema:    RECOMMENDATION_SCHEMA,
          tool_name: TOOL_NAME,
          tags:      [ "enliterator", "considerer" ]
        )
        batch_summary = apply!(Array(result["recommendations"] || result[:recommendations]), canonical, slice)
        aggregate.each_key { |k| aggregate[k] += batch_summary[k] }
        done += slice.size
        yield(done, terms.size) if block_given?
      end

      aggregate
    end

    private

    # The open terms whose PENDING proposals live in the current scope (pressure
    # itself stays a global signal on ProposedTerm).
    def scoped_terms
      pending_keys = Enliterator::Suggestion.pending
                       .where(context_id: @context&.id)
                       .distinct.pluck(:proposed_key)
      Enliterator::ProposedTerm.open.by_pressure.where(proposed_key: pending_keys).to_a
    end

    def adapter
      return @llm if @llm
      tier = Enliterator.configuration.considerer_tier || Enliterator.staffing.ladder.last || "quality"
      Enliterator.llm(tier: tier)
    end

    # Every term in the current context's EFFECTIVE vocabulary (inherited + own,
    # code + approved) — valid map targets, so the considerer can map a synonym
    # onto a newly-approved or inherited term.
    def canonical_keys
      Enliterator.staffing.facets_for(@context&.path_keys).keys
        .flat_map { |s| (Enliterator::Vocabulary.for(s, context: @context) || {}).keys }.uniq.sort
    end

    def apply!(recs, canonical, terms)
      summary = empty_summary.merge(considered: terms.size)
      by_key  = terms.index_by(&:proposed_key)

      recs.each do |r|
        key = (r["proposed_key"] || r[:proposed_key]).to_s
        next if key.empty?
        term      = by_key[key]
        decision  = (r["decision"]   || r[:decision]).to_s
        conf      = (r["confidence"] || r[:confidence]).to_f
        map_to    = (r["map_to"]     || r[:map_to]).to_s
        rationale = (r["rationale"]  || r[:rationale]).to_s

        case decision
        when "map"
          if @autonomy == :auto_safe && conf >= @min_confidence && canonical.include?(map_to)
            Enliterator::Suggestion.map_key!(key, to: map_to, note: "considerer: #{rationale}", context: @context)
            term&.clear_recommendation!
            summary[:auto_mapped] += 1
          else
            term&.record_recommendation!(decision: "map", map_to: map_to, rationale: rationale, confidence: conf)
            summary[:held] += 1
          end
        when "reject"
          if @autonomy == :auto_safe && conf >= @min_confidence
            Enliterator::Suggestion.reject_key!(key, note: "considerer: #{rationale}", context: @context)
            term&.clear_recommendation!
            summary[:auto_rejected] += 1
          else
            term&.record_recommendation!(decision: "reject", rationale: rationale, confidence: conf)
            summary[:held] += 1
          end
        when "approve"
          # A contract change — ALWAYS human-ratified, never auto-applied.
          term&.record_recommendation!(decision: "approve", rationale: rationale, confidence: conf)
          summary[:approves_recommended] += 1
        else
          summary[:held] += 1
        end
      end

      summary
    end

    def empty_summary
      { considered: 0, auto_mapped: 0, auto_rejected: 0, approves_recommended: 0, held: 0 }
    end

    def messages_for(terms, canonical)
      [ { role: "system", content: system_prompt(canonical) },
        { role: "user",   content: user_prompt(terms) } ]
    end

    def system_prompt(canonical)
      <<~SYS.strip
        You tend the CONTROLLED VOCABULARY of an enliteration. While tending records the
        model proposed claim keys the facets' contracts don't cover. For EACH proposed
        key decide exactly one:
          - map: a synonym/variant of an existing canonical key — set `map_to` to an EXACT
            key from the list below. Prefer this over approving a near-duplicate.
          - approve: a genuinely new, durable concept the contract should adopt — optionally
            give a clean `canonical_name`.
          - reject: noise, too specific, redundant, or it belongs to another facet's role.
        Weigh PRESSURE (demand). Treat resurged>0 (re-proposed after a prior verdict) as a
        strong signal the key was wrongly dismissed. Give a one-line rationale and a
        confidence in [0,1] per key.

        EXISTING CANONICAL KEYS (valid map_to targets): #{canonical.join(', ')}
      SYS
    end

    def user_prompt(terms)
      lines = terms.map do |t|
        facets = t.by_facet.keys.join("/")
        resurged = t.resurged_count.to_i.positive? ? ", RESURGED #{t.resurged_count}" : ""
        eg = t.sample_example.present? ? " — e.g. #{render(t.sample_example)}" : ""
        "- #{t.proposed_key}  [pressure #{t.pressure}, #{t.distinct_records} records, facets: #{facets}#{resurged}]\n    #{t.sample_rationale.to_s[0, 140]}#{eg}"
      end
      <<~USER.strip
        Decide these #{terms.size} proposed keys (highest pressure first):

        #{lines.join("\n")}
      USER
    end

    def render(value)
      s = value.is_a?(String) ? value : value.to_json
      s.length > 80 ? "#{s[0, 80]}…" : s
    end
  end
end
