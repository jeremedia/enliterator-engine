# The async considerer run ledger. One row per consider! invocation triggered
# from the UI. Written at START (started_at, status "running"); progress is
# stamped by the progress block (done_count/planned_count/pulse_at/phase);
# finalized at the end (finished_at, status "finished", summary). A row with
# NULL finished_at past the REAP_AFTER window is an orphan — its process died.
class CreateEnliteratorConsidererRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_considerer_runs do |t|
      t.bigint   :context_id                            # nil = root scope
      t.string   :status                                # running | finished | reaped | error
      t.string   :phase                                 # "considering" while running, "done" when finished
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :pulse_at                              # liveness signal — the reaper reads this
      t.text     :error
      t.integer  :planned_count                         # total terms — set on first yield
      t.integer  :done_count, default: 0               # terms processed so far
      t.jsonb    :summary, default: {}                  # the consider! return hash when finished
      t.integer  :batch_size                            # snapshot of the config at run time
      t.timestamps
    end
    add_index :enliterator_considerer_runs, :finished_at
  end
end
