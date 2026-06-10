# v0.23: liveness + phase on the ledger row. `pulse_at` is touched at every
# phase boundary and inside every LLM loop — the row always knows when it
# last moved, in phases that produce no visits (considerer/conservator/audit)
# as much as in the work phase. `phase` names where the cycle is, so the
# monitor can say "running audit…" and the reaper can name where an orphaned
# cycle died. Cycle #12 (orphaned mid-audit by a server restart, unfindable
# from the row alone) is the motivating patient.
class AddPulseToEnliteratorHeartbeats < ActiveRecord::Migration[8.1]
  def change
    add_column :enliterator_heartbeats, :pulse_at, :datetime
    add_column :enliterator_heartbeats, :phase, :string
  end
end
