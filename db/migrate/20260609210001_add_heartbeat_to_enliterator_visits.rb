# v0.15: visit-level cycle provenance. Every Visit a heartbeat causes carries
# the cycle that caused it (heartbeat_id) and WHY it was scheduled (reason:
# frontier | source_change | neighborhood | vocabulary | sweep). PROV all the
# way down — the Heartbeat is the Activity that informed the Visit. NULLABLE by
# design: every manual/legacy tend keeps NULL (byte-identical when unused), and
# enqueue-mode actuals stay derivable later via Visit.where(heartbeat_id:).
class AddHeartbeatToEnliteratorVisits < ActiveRecord::Migration[8.1]
  def change
    add_reference :enliterator_visits, :heartbeat,
                  null: true, foreign_key: { to_table: :enliterator_heartbeats }
    add_column :enliterator_visits, :reason, :string
  end
end
