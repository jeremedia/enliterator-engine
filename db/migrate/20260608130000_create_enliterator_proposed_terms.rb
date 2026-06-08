# v0.8: the materialized pressure aggregate for the considerer. One row per
# proposed_key, recomputed from the Suggestion proposal log. Pressure is the
# INTEGRAL of demand across tending passes; resurged_count is the count of
# proposals that came back AFTER a verdict (the model overruling the curator).
# The recommendation_* fields hold the considerer's held-for-ratification verdict.
class CreateEnliteratorProposedTerms < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_proposed_terms do |t|
      t.string  :proposed_key, null: false
      t.integer :pressure,         null: false, default: 0  # total proposals ever
      t.integer :distinct_records, null: false, default: 0
      t.jsonb   :by_stream,        null: false, default: {} # {stream => count}
      t.integer :resurged_count,   null: false, default: 0  # proposals after a verdict
      t.datetime :first_seen_at
      t.datetime :last_seen_at

      # The considerer's held recommendation (when not auto-applied — i.e. approves
      # and low-confidence calls awaiting human ratification).
      t.string  :recommended_decision   # approve | map | reject
      t.string  :recommended_map_to
      t.text    :recommended_rationale
      t.float   :recommended_confidence
      t.datetime :considered_at

      t.text  :sample_rationale
      t.jsonb :sample_example, default: {}

      t.timestamps
    end

    add_index :enliterator_proposed_terms, :proposed_key, unique: true
    add_index :enliterator_proposed_terms, :pressure
  end
end
