# v0.15: the lane-scan index. The heartbeat planner's hot queries lead on
# (context, facet) — the neighborhood window scan, the trigger anchors, the
# frontier anti-joins — and the only context-leading index until now was the
# bare context_id reference index. Additive; nothing else changes.
class AddLaneScanIndexToEnliteratorVisits < ActiveRecord::Migration[8.1]
  def change
    add_index :enliterator_visits, [ :context_id, :facet, :created_at ],
              name: "idx_enliterator_visits_on_context_facet_created"
  end
end
