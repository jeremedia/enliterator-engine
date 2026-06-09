# v0.17: Condition. One new table — the conservator's treatment proposals,
# keyed by failure SIGNATURE (a stable fingerprint of which probes failed and
# how). No status machine: the failure piles are LIVE (a fixed record passes
# its next survey and leaves its pile), so resolution is MEASURED, never
# asserted; treatment rows persist as the explanation attached to a signature
# whenever its pile has members. Plus the three indexes the survey + gate
# queries need, and the heartbeat ledger's survey column.
class CreateEnliteratorTreatments < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_treatments do |t|
      t.string   :signature, null: false      # sorted "probe:code" pairs joined "+"
      t.integer  :rung                        # worst failing probe's registry position (display)
      t.text     :diagnosis                   # the conservator's plain-language reading
      t.text     :treatment                   # the proposal for staff (augments probe remediation)
      t.float    :confidence
      t.jsonb    :sample, default: []         # [[type, id, title], ...] at last consideration
      t.integer  :last_seen_count             # the pile's size when last considered (delta gate)
      t.datetime :last_seen_at
      t.datetime :considered_at
      t.string   :tier
      t.string   :model
      t.timestamps
    end
    add_index :enliterator_treatments, :signature, unique: true

    # Stalest-first survey ordering (the rolling shelf-read).
    add_index :enliterator_measures, [ :name, :computed_at ],
              name: "idx_enliterator_measures_on_name_computed"
    # The untendable gate's anti-join target: contains ONLY untendable rollup
    # rows (thousands at most), so excluding them from candidate queries is
    # nearly free at any corpus size.
    add_index :enliterator_measures, [ :tendable_type, :tendable_id ],
              name: "idx_enliterator_measures_untendable",
              where: "name = 'condition' AND score = 0.0"

    add_column :enliterator_heartbeats, :survey, :jsonb, default: {}
  end
end
