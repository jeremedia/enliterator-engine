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
      keyword_init: true
    ) do
      # Identical formula to Audit.accuracy: unverifiable is excluded from the
      # denominator (the source could not decide, which is not the reader's fault).
      def supported_rate
        decided = counts["supported"] + counts["unsupported"] + counts["contradicted"]
        decided.positive? ? (counts["supported"].to_f / decided).round(3) : nil
      end

      def claims_per_record = records.positive? ? (claims.to_f / records).round(2) : 0.0
      def tokens_per_claim  = claims.positive? ? (tokens.to_f / claims).round(0).to_i : 0
    end

    def self.run(records, **kwargs) = new(records, **kwargs).run

    # @param records [Enumerable] tendables to read
    # @param facet [String] the facet each tier reads along
    # @param tiers [Array<String>] the candidate tier aliases
    # @param examiner [Audit::Examiner] ONE instrument for every arm (default: the
    #   host's configured audit tier — the same examiner the standing audit uses)
    def initialize(records, facet:, tiers:, context: nil, examiner: nil, progress: nil)
      @records  = Array(records)
      @facet    = facet.to_s
      @tiers    = Array(tiers).map(&:to_s)
      @context  = context
      @examiner = examiner || Enliterator::Audit::Examiner.new
      @progress = progress
    end

    def run
      @tiers.map { |tier| measure(tier) }
    end

    private

    def measure(tier)
      started  = Time.current
      adapter  = Enliterator.llm(tier: tier)
      counts   = Hash.new(0).tap { |h| VERDICTS.each { |v| h[v] = 0 } }
      claims   = 0
      tokens   = 0
      errors   = []
      model    = nil

      @records.each do |record|
        source = record.enliterator_text(facet: @facet).to_s
        next if source.strip.empty?

        begin
          response = read(adapter, record, source)
          tokens  += token_total(response)
          model  ||= (response.respond_to?(:model) ? response.model.presence : nil) ||
                     (adapter.respond_to?(:model_id) ? adapter.model_id : tier)

          produced = Array((response.parsed || {})["claims"])
          produced.each do |c|
            key   = c["key"] || c[:key]
            value = c["value"] || c[:value]
            next if key.blank?

            claims += 1
            verdict = examine(key, value, source)
            counts[verdict] += 1 if verdict
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
        errors: errors
      )
    end

    # The examiner never learns which tier produced this — that blindness is what
    # makes the comparison worth running.
    def examine(key, value, source)
      rendered = @examiner.verdict_for(
        facet: @facet, key: key, value: value, context: @context, source: source
      )
      rendered.is_a?(Hash) ? rendered[:verdict] : nil
    end

    def read(adapter, record, source)
      kwargs = { text: source, facet: @facet, state: {}, neighbors: [] }
      kwargs[:tags]     = [ "enliterator", "bakeoff" ]                       if accepts?(adapter, :tags)
      contract = Enliterator::Vocabulary.for(@facet, context: @context)
      kwargs[:contract] = contract                                           if contract.present? && accepts?(adapter, :contract)
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
