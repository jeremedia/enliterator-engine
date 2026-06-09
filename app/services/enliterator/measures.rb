module Enliterator
  # Registry of named quality measures. Each measure is a block that takes a tendable
  # and returns {score: Float, signals: Hash}. recompute! runs all registered
  # measures and upserts a Measure row per [tendable, name]. Host apps register their
  # own (HSDL maps its 12-signal health here); the engine ships :completeness.
  module Measures
    @registry = {}

    class << self
      # Register (or replace) a measure by name. The block receives the tendable and
      # must return {score: Float (0..1), signals: Hash}.
      def register(name, &block)
        @registry[name.to_sym] = block
        name.to_sym
      end

      def registry
        @registry
      end

      # Run every registered measure against the tendable and upsert its Measure row.
      # Returns the array of persisted Measure records.
      def recompute!(tendable)
        load_default!
        now = Time.current
        registry.map do |name, block|
          result  = block.call(tendable)
          score   = result[:score]
          signals = result[:signals] || {}

          measure = tendable.enliterator_measures.find_or_initialize_by(name: name.to_s)
          measure.score       = score
          measure.signals     = signals
          measure.computed_at = now
          measure.save!
          measure
        end
      end

      # Idempotently register the built-in :completeness measure.
      def load_default!
        return if registry.key?(:completeness)

        register(:completeness) do |tendable|
          has_claim     = tendable.enliterator_claims.live.exists?
          has_embedding = tendable.enliterator_embeddings.where(kind: "primary").exists?
          has_visit     = tendable.enliterator_visits.where(status: "succeeded").exists?

          checks = {
            "has_live_claim"      => has_claim,
            "has_primary_embedding" => has_embedding,
            "has_succeeded_visit" => has_visit
          }
          present = checks.values.count(true)
          total   = checks.size

          signals = checks.transform_values { |v| { value: v, weight: 1.0 } }

          { score: total.zero? ? 0.0 : present.to_f / total, signals: signals }
        end
      end
    end
  end
end
