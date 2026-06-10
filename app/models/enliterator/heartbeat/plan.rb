module Enliterator
  class Heartbeat < ApplicationRecord
    # The planner's result — an ordered, budget-bounded work queue plus the
    # accounting that makes it auditable: counts by reason × lane, the frontier
    # horizon (how many cycles to read everything at this budget), and a
    # warning for every omission (truncation, suppression, fallback). Pure
    # value object; beat! executes it, the Status preview renders it.
    class Plan
      Item = Struct.new(:tendable_type, :tendable_id, :facet, :context, :reason, :est_tokens,
                        keyword_init: true) do
        def lane
          "#{context&.key || 'root'}/#{facet}"
        end

        # Materialize the host record (string tendable_id cast through the
        # model's own primary key — works for bigint and uuid PKs alike).
        def record
          klass = tendable_type.constantize
          klass.find_by(klass.primary_key => tendable_id)
        rescue NameError
          nil
        end
      end

      attr_reader :budget, :change_cap, :items, :warnings,
                  :frontier_remaining, :horizon_tokens

      def initialize(budget:, change_cap:, items:, warnings:, frontier_remaining:, horizon_tokens:)
        @budget             = budget
        @change_cap         = change_cap
        @items              = items
        @warnings           = warnings
        # {lane_label => untended count} BEFORE this cycle — the whole shelf.
        @frontier_remaining = frontier_remaining
        @horizon_tokens     = horizon_tokens
      end

      # v0.20: the polymorphic preview interface shared with PreparedPlan —
      # views ask work?/as_of and never branch on the plan's source.
      def work? = items.any?
      def as_of = nil

      def counts
        items.group_by(&:reason).transform_values(&:size)
      end

      def lane_counts
        items.group_by(&:lane).transform_values { |is| is.group_by(&:reason).transform_values(&:size) }
      end

      def est_total
        items.sum(&:est_tokens)
      end

      def frontier_total
        frontier_remaining.values.sum
      end

      # Cycles to drain the remaining frontier at this budget — the math that
      # makes the budget an owned decision instead of an accidental schedule.
      def horizon_cycles
        return 0 if horizon_tokens.zero? || budget.zero?
        (horizon_tokens / budget.to_f).ceil
      end

      def horizon_line
        return "frontier: clear" if frontier_total.zero?
        "frontier: #{frontier_total} record(s) remaining ≈ #{horizon_cycles} cycle(s) at #{budget} tokens/cycle"
      end

      # The jsonb shape persisted on the ledger row's `planned` column.
      def to_ledger
        {
          "counts"             => counts,
          "lanes"              => lane_counts,
          "est_total"          => est_total,
          "frontier_remaining" => frontier_remaining,
          "frontier_total"     => frontier_total,
          "horizon_cycles"     => horizon_cycles,
          "warnings"           => warnings
        }
      end
    end
  end
end
