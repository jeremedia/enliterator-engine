module Enliterator
  class Heartbeat < ApplicationRecord
    # v0.20: the PREPARED plan — a ledger row's `planned` jsonb, read back as
    # the same interface the previews render from a live Plan. The finding-aid
    # principle: a page presents the prepared document (with its revision
    # date, `as_of`), it does not re-census 300K host rows per view. The live
    # census still runs where it is authoritative: `open!` re-plans when a
    # beat actually starts, and `rake enliterator:heartbeat PLAN=1` is the
    # on-demand inventory.
    class PreparedPlan
      def initialize(heartbeat)
        @heartbeat = heartbeat
        @planned   = heartbeat.planned || {}
      end

      def counts         = @planned.fetch("counts", {})
      def lane_counts    = @planned.fetch("lanes", {})
      def est_total      = @planned.fetch("est_total", 0)
      def warnings       = @planned.fetch("warnings", [])
      def frontier_total = @planned.fetch("frontier_total", 0)
      def horizon_cycles = @planned.fetch("horizon_cycles", 0)

      # The budget this plan was computed against — that cycle's, not the
      # config default (the honest pairing for est_total).
      def budget = @heartbeat.budget_tokens

      def work? = counts.values.sum.positive?

      # The revision date: [cycle id, planned-at]. Live Plan returns nil here;
      # the views render the as-of line only when present.
      def as_of = [ @heartbeat.id, @heartbeat.started_at ]

      # Must stay textually identical to Plan#horizon_line (spec-pinned).
      def horizon_line
        return "frontier: clear" if frontier_total.zero?
        "frontier: #{frontier_total} record(s) remaining ≈ #{horizon_cycles} cycle(s) at #{budget} tokens/cycle"
      end
    end
  end
end
