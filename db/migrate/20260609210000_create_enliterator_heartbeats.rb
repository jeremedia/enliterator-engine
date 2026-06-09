# v0.15: the cycle ledger. One row per heartbeat — the auditable record of what
# the scheduler planned, why, and what it actually spent. Written at START
# (started_at + planned + config_snapshot; the open row doubles as the overlap
# lock), finalized at the end (finished_at + executed + actuals). A row with
# NULL finished_at past its window is crash evidence, not silence.
class CreateEnliteratorHeartbeats < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_heartbeats do |t|
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string   :mode, null: false, default: "sync"   # sync | enqueue
      t.bigint   :budget_tokens
      t.jsonb    :planned,         default: {}          # counts by reason × lane + horizon
      t.jsonb    :executed,        default: {}          # succeeded/failed counts by reason × lane
      t.jsonb    :tokens_spent,    default: {}          # sync actuals; enqueue derivable via visits
      t.jsonb    :considerer,      default: {}          # the cycle's vocabulary-governance outcome
      t.jsonb    :config_snapshot, default: {}          # reproducibility: knobs at plan time
      t.jsonb    :warnings,        default: []          # every omission/suppression says why
      t.text     :error
      t.timestamps
    end
    add_index :enliterator_heartbeats, :started_at
  end
end
