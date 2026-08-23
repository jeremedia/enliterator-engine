# frozen_string_literal: true

module Enliterator
  # v0.70 — WHICH READER SHOULD STAFF THIS FACET.
  #
  # A tier's backend can change (a gateway repoint, a cost decision, a compliance
  # directive), and the question that follows is always the same: is the new reader
  # as good as the old one on THIS collection? The tempting answer is the tending
  # log's average confidence — and it is worthless, because confidence is
  # self-reported. A model that rates itself 0.87 is not more right than one that
  # rates itself 0.72; it is more confident, which is a property of the model, not
  # of the claims.
  #
  # The bake-off answers it with the instrument the collection already trusts: the
  # blind, source-grounded `Audit::Examiner`. Each candidate tier reads the same
  # records; every claim it produces is examined against the record's own source by
  # ONE examiner that is never told which tier produced it. The output is a
  # `supported_rate` computed exactly as `Audit.accuracy` computes it, so a
  # bake-off number and the standing audit number mean the same thing.
  #
  # WRITES NOTHING. No Visit, no Claim, no Audit, no Embedding. Claims are produced
  # in memory and examined in memory. Measuring a candidate reader must not deposit
  # that reader's opinions in the live claim store — that would be the experiment
  # contaminating the collection it is trying to protect.
  #
  # Deliberately reads WITHOUT prior state or neighbors: each tier gets the source
  # and nothing else. This measures the READ, not the compounding — handing a model
  # the existing claims invites it to echo them, which flatters every candidate
  # equally and tells you nothing about who reads better.
  class Bakeoff
    VERDICTS = %w[supported unsupported contradicted unverifiable].freeze

    Outcome = Struct.new(
      :tier, :model, :records, :claims, :counts, :tokens, :elapsed_s, :errors,
      :required_terms, :required_met, :required_expected,
      :abstained, :abstention_counts,
      keyword_init: true
    ) do
      # PRECISION — v0.72: DELEGATES to Audit.rate, the one definition. The
      # v0.70 header said "identical formula to Audit.accuracy" without
      # enforcing it; now a bake-off number and the standing audit number are
      # the same computation, not a maintained coincidence.
      def supported_rate = Enliterator::Audit.rate(counts)

      # RECALL, as far as the engine can see it. `supported_rate` alone rewards a
      # reader for saying LESS: emit two safe claims instead of six and precision
      # goes up while the collection learns less. Required terms are the one place
      # the engine knows what SHOULD have been produced, so on a facet that
      # declares them this is the counterweight — a reader that quietly omits the
      # author scores 1.0 on precision and fails here.
      #
      # nil when the facet declares no required terms (most facets) — an honest
      # absence, not a zero.
      def coverage
        return nil unless required_expected.to_i.positive?
        (required_met.to_f / required_expected).round(3)
      end

      def claims_per_record = records.positive? ? (claims.to_f / records).round(2) : 0.0
      def tokens_per_claim  = claims.positive? ? (tokens.to_f / claims).round(0).to_i : 0

      # v0.72.5 — ABSTENTION, its own metric, never folded into precision.
      # Folding correct-abstention into `supported` lets a quiet reader inflate
      # precision (the quiet-reader trap in a new costume); excluding empties
      # entirely makes virtuous restraint and damaging silence look identical.
      # `supported_rate` is FILLED claims only; this is: of the empty claims,
      # what fraction did the source support? Low density + high
      # abstention-accuracy = restraint; low density + low = damaging silence.
      # nil when the reader never abstained — an honest absence, not a zero.
      def abstention_accuracy = Enliterator::Audit.rate(abstention_counts || {})
    end

    def self.run(records, **kwargs) = new(records, **kwargs).run

    # @param records [Enumerable] tendables to read
    # @param facet [String] the facet each tier reads along
    # @param tiers [Array<String>] the candidate tier aliases
    # @param examiner [Audit::Examiner] ONE instrument for every arm (default: the
    #   host's configured audit tier — the same examiner the standing audit uses)
    def initialize(records, facet:, tiers:, context: nil, examiner: nil, progress: nil, required: nil)
      @records  = Array(records)
      @facet    = facet.to_s
      @tiers    = Array(tiers).map(&:to_s)
      @context  = context
      @examiner = examiner || Enliterator::Audit::Examiner.new
      @progress = progress
      # Default to the staffing policy's own declaration so an arm is measured on
      # the same obligation production imposes.
      @required = Array(required.nil? ? default_required : required).map(&:to_s)
    end

    def run
      @tiers.map { |tier| measure(tier) }
    end

    private

    def measure(tier)
      started  = Time.current
      adapter  = Enliterator.llm(tier: tier)
      counts   = Hash.new(0).tap { |h| VERDICTS.each { |v| h[v] = 0 } }
      abst     = Hash.new(0)
      claims   = 0
      tokens   = 0
      errors   = []
      model    = nil
      req_met  = 0
      req_seen = 0

      @records.each do |record|
        source = record.enliterator_text(facet: @facet).to_s
        next if source.strip.empty?

        begin
          response = read(adapter, record, source)
          tokens  += token_total(response)
          model  ||= (response.respond_to?(:model) ? response.model.presence : nil) ||
                     (adapter.respond_to?(:model_id) ? adapter.model_id : tier)

          produced = Array((response.parsed || {})["claims"])
          filled   = {}
          produced.each do |c|
            key   = c["key"] || c[:key]
            value = c["value"] || c[:value]
            next if key.blank?

            # A required term is MET only by a non-blank value. An empty claim is
            # the very thing v0.46's lacunae exist to stop counting as an answer.
            filled[key.to_s] = true if value.present?

            claims += 1
            verdict = examine(key, value, source)
            next unless verdict
            # v0.72.5: empties aggregate SEPARATELY. Before this, an empty
            # claim was excluded from coverage but coin-flip-scored into
            # precision — the asymmetry resolved by the absence verdict.
            if Enliterator::Claim.blank_value?(value)
              abst[verdict] += 1
            else
              counts[verdict] += 1
            end
          end

          # Recall, per record: did this reader produce what the facet obliges?
          @required.each do |term|
            req_seen += 1
            req_met  += 1 if filled[term]
          end

          @progress&.call(tier: tier, record: record, claims: produced.size)
        rescue StandardError => e
          # One bad record must not void the arm — record it and keep measuring
          # (rule 3: never silent; the report prints the count).
          errors << "#{record.class}/#{record.id}: #{e.class}: #{e.message[0, 120]}"
        end
      end

      Outcome.new(
        tier: tier, model: model || tier, records: @records.size, claims: claims,
        counts: counts, tokens: tokens, elapsed_s: (Time.current - started).round(1),
        errors: errors, required_terms: @required, required_met: req_met,
        required_expected: req_seen,
        abstained: abst.values.sum, abstention_counts: abst
      )
    end

    def default_required
      Enliterator.staffing.required_terms(@facet, path: Array(@context&.path_keys))
    rescue StandardError
      []
    end

    # The examiner never learns which tier produced this — that blindness is what
    # makes the comparison worth running.
    #
    # truncated: false is EXPLICIT and correct: the bake-off sends the FULL
    # `enliterator_text` with no `audit_source_chars` ceiling, so it has no
    # truncation to report. (Adopting the ceiling would shift bake-off numbers
    # against v0.70's — deliberately not done.) On empty claims this makes the
    # examiner's `supported` branch available: the source is whole.
    def examine(key, value, source)
      rendered = @examiner.verdict_for(
        facet: @facet, key: key, value: value, context: @context, source: source,
        truncated: false
      )
      rendered.is_a?(Hash) ? rendered[:verdict] : nil
    end

    def read(adapter, record, source)
      kwargs = { text: source, facet: @facet, state: {}, neighbors: [] }
      kwargs[:tags]     = [ "enliterator", "bakeoff" ] if accepts?(adapter, :tags)
      contract = Enliterator::Vocabulary.for(@facet, context: @context)
      kwargs[:contract] = contract if contract.present? && accepts?(adapter, :contract)
      # The required-terms instruction is part of the job. Measuring coverage
      # without it would score readers on an obligation they were never given.
      kwargs[:required] = @required if @required.present? && accepts?(adapter, :required)
      adapter.tend(**kwargs)
    end

    def accepts?(adapter, name)
      adapter.method(:tend).parameters.any? { |type, pname| pname == name && %i[key keyreq].include?(type) }
    rescue NameError
      false
    end

    def token_total(response)
      t = response.respond_to?(:tokens) ? response.tokens : nil
      return 0 unless t.is_a?(Hash)
      (t["total"] || t[:total] || 0).to_i
    end
  end
end
