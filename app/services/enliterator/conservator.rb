module Enliterator
  # v0.17 — the conservator. The Considerer pattern turned on the CONDITION of
  # the collection: mechanical probes accumulate failure piles; one agent call
  # reads the whole field and writes, per pile, a plain-language DIAGNOSIS and
  # a TREATMENT proposal for collections staff — what is required to bring
  # these records into the tending loop. The probe author's `remediation` is
  # fed in as the primary fact; the agent augments, prioritizes, and explains —
  # it never invents host procedures it cannot know.
  #
  # Treatments key on the pile's SIGNATURE; the model answers by positional id
  # (s1, s2, …) so a reworded echo can never create a phantom row. A delta
  # gate skips the call entirely when no pile changed since last assessment.
  # Resolution is MEASURED, never asserted: a fixed record passes its next
  # survey and leaves its pile; the treatment row persists as the explanation.
  class Conservator
    TOOL_NAME = "write_treatments".freeze
    MAX_PILES = 12
    SAMPLE_TITLES = 3

    SCHEMA = {
      "type" => "object",
      "properties" => {
        "treatments" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "id"         => { "type" => "string", "description" => "the pile id EXACTLY as given (s1, s2, …)" },
              "diagnosis"  => { "type" => "string", "description" => "plain language: what is wrong with these records and why they cannot be tended (or understood)" },
              "treatment"  => { "type" => "string", "description" => "what staff should do — augment the stated remediation; never invent procedures not stated" },
              "confidence" => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0 }
            },
            "required" => %w[id diagnosis treatment confidence]
          }
        }
      },
      "required" => %w[treatments]
    }.freeze

    def initialize(llm: nil, tier: nil)
      @llm  = llm
      @tier = tier
    end

    # Assess the field. Returns a summary hash (always; soft-degrades without
    # an LLM — assessment writes prose, not facts, so it never raises).
    def assess!
      field = build_field
      return log_skip("no failure piles — the shelf is clean") if field.empty?

      record_sightings!(field)
      changed = field.select { |p| p[:changed] }
      return log_skip("piles unchanged since last assessment — call skipped") if changed.empty?

      considered = changed.sort_by { |p| -p[:count] }.first(MAX_PILES)
      if changed.size > considered.size
        log("#{changed.size - considered.size} changed pile(s) beyond the top #{MAX_PILES} — unconsidered this cycle")
      end

      adapter = resolve_llm
      if adapter.is_a?(Enliterator::Adapters::LLM::Null)
        return log_skip("no LLM configured — sightings recorded, diagnoses deferred")
      end

      result = adapter.decide(
        messages:  messages_for(considered),
        schema:    SCHEMA,
        tool_name: TOOL_NAME,
        tags:      [ "enliterator", "conservator" ]
      )
      written = apply!(result, considered, adapter)
      { piles: field.size, changed: changed.size, diagnosed: written }
    end

    private

    # The field: live condition piles + the rung-4 residue as a synthetic pile
    # in the same keyspace (one upsert mechanism, one report table).
    def build_field
      piles = Enliterator::Condition.piles(sample_limit: SAMPLE_TITLES).map do |p|
        p.merge(kind: :source, remediation: remediation_of(p))
      end
      residue = Enliterator::Condition.residue(limit: SAMPLE_TITLES)
      if residue.any?
        piles << {
          signature: Enliterator::Condition::RESIDUE_SIGNATURE,
          band: "residue", kind: :residue,
          count: Enliterator::Condition.residue_count,
          failing: {}, remediation: nil,
          samples: residue.map { |r| [ r[:tendable_type], r[:tendable_id] ] }
        }
      end
      piles
    end

    def remediation_of(pile)
      pile[:failing].values.filter_map { |f| f["remediation"] }.uniq.join(" / ").presence
    end

    # Upsert each pile's sighting (count, time, rung, samples) and mark which
    # changed vs the last assessment — the delta gate's memory.
    def record_sightings!(field)
      existing = Enliterator::Treatment.where(signature: field.map { |p| p[:signature] })
                                       .index_by(&:signature)
      now = Time.current
      field.each do |pile|
        row = existing[pile[:signature]]
        pile[:changed] = row.nil? || row.last_seen_count != pile[:count]
        row ||= Enliterator::Treatment.new(signature: pile[:signature])
        row.assign_attributes(
          rung:            rung_of(pile),
          last_seen_count: pile[:count],
          last_seen_at:    now,
          sample:          pile[:samples].map { |type, id| [ type, id, title_of(type, id) ] }
        )
        row.save!
        pile[:row] = row
      end
    end

    # Display rung = the worst failing probe's registry position (derived at
    # read time — never embedded in the signature, so registry renumbering
    # cannot orphan a treatment). Residue sits past every probe.
    def rung_of(pile)
      return Enliterator::Condition.registry.size + 1 if pile[:kind] == :residue
      positions = pile[:failing].keys.filter_map do |probe|
        Enliterator::Condition.registry.dig(probe.to_sym, :position)
      end
      positions.min
    end

    def title_of(type, id)
      klass = type.safe_constantize
      record = klass && klass.find_by(klass.primary_key => id)
      return nil if record.nil?
      record.try(:title).presence || record.enliterator_text.to_s[0, 60]
    rescue StandardError
      nil
    end

    def apply!(result, considered, adapter)
      by_id = considered.each_with_index.to_h { |pile, i| [ "s#{i + 1}", pile ] }
      items = Array(result["treatments"] || result[:treatments])
      written = 0
      items.each do |t|
        pile = by_id[(t["id"] || t[:id]).to_s]
        next if pile.nil?   # an id the prompt never issued — dropped, not guessed
        pile[:row].update!(
          diagnosis:     (t["diagnosis"]  || t[:diagnosis]).to_s,
          treatment:     (t["treatment"]  || t[:treatment]).to_s,
          confidence:    (t["confidence"] || t[:confidence]).to_f,
          considered_at: Time.current,
          tier:          effective_tier.to_s,
          model:         adapter.respond_to?(:model_id) ? adapter.model_id : nil
        )
        written += 1
      end
      written
    end

    def resolve_llm
      return @llm if @llm
      Enliterator.llm(tier: effective_tier)
    end

    def effective_tier
      @tier || Enliterator.configuration.considerer_tier ||
        Enliterator.staffing.ladder.last || "quality"
    end

    def messages_for(considered)
      [ { role: "system", content: <<~SYS.strip },
          You are the CONSERVATOR of an enliterated collection. A mechanical survey has
          grouped records that cannot be tended (or could not be understood) into FAILURE
          PILES. For EACH pile, write for collections staff:
            - diagnosis: plain language — what is wrong with these records.
            - treatment: what is required to bring them into the tending loop. The stated
              REMEDIATION for each pile is ground truth from the probe's author — augment
              and prioritize it; NEVER invent procedures, system names, or steps that are
              not stated or directly implied by the signals.
          Answer with each pile's id EXACTLY as given. Note: source-condition piles and the
          tending-quality pile (records the engine read but never understood) are different
          remediation universes — do not blend their advice.
        SYS
        { role: "user", content: user_prompt(considered) } ]
    end

    def user_prompt(considered)
      lines = considered.each_with_index.map do |pile, i|
        titles = pile[:row].sample.filter_map { |(_t, _id, title)| title }.first(SAMPLE_TITLES)
        kind = pile[:kind] == :residue ? "TENDING-QUALITY (read but never understood)" : "SOURCE-CONDITION"
        <<~PILE.strip
          [s#{i + 1}] #{kind} — #{pile[:count]} record(s) — failure: #{pile[:signature]}
            signals: #{pile[:failing].map { |probe, f| "#{probe}=#{f['code']}#{" (#{f['note']})" if f['note']}" }.join('; ').presence || '(none — condition sound; tending yields nothing)'}
            stated remediation: #{pile[:remediation] || '(none stated)'}
            samples: #{titles.any? ? titles.join(' | ') : '(untitled)'}
        PILE
      end
      "Assess these #{considered.size} pile(s):\n\n#{lines.join("\n\n")}"
    end

    def log_skip(msg)
      log(msg)
      { skipped: msg }
    end

    def log(msg)
      Enliterator.logger&.info("[enliterator:conservator] #{msg}")
    rescue StandardError
      nil
    end
  end
end
