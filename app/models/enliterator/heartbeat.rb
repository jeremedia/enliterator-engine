module Enliterator
  # v0.15: one row = one heartbeat cycle. The model IS the scheduler — the
  # cycle is a record (PROV Activity), so planning, execution, and audit share
  # one identity. Heartbeat.plan computes the event-driven work queue (pure
  # read); Heartbeat.beat! opens a row (the overlap lock), executes the plan
  # under the token budget, runs the considerer, and finalizes the ledger.
  # Filled in across v0.15's phases — this file starts as the ledger.
  class Heartbeat < ApplicationRecord
    MODES = %w[sync enqueue].freeze

    has_many :visits, class_name: "Enliterator::Visit", dependent: :nullify

    # An open row younger than the overlap window is a running (or crashed)
    # cycle — beat! refuses to start another without force.
    scope :unfinished, -> { where(finished_at: nil) }

    # Compute the next cycle's work queue — PURE READ, no writes, no network.
    # The standing preview (Status) and the dry-run (PLAN=1) both read this.
    def self.plan(budget: nil)
      Planner.new(budget: budget).plan
    end

    def finished? = finished_at.present?
  end
end
