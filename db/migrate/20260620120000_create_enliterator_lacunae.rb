# v0.46: Lacunae — the collection's knowledge of its own gaps. A first-class
# finding (sibling to Suggestion/Treatment) opened when a *required* term comes
# back unmet during tending, and closed when a later visit supplies it. The
# negative space of a claim. Gated behind config.record_lacunae (default off) —
# empty table ⇒ byte-identical.
#
# tendable_type/tendable_id are STRING (matching Claim) so one polymorphic column
# serves both a bigint-PK host (the dummy Widget) and a uuid-PK host (HSDL
# DocMetum). context_id is bigint, NULL = root. The partial unique index keeps
# ONE open lacuna per (tendable, facet, key, context) — `nulls_not_distinct: true`
# (PG15+; the engine is Postgres-only) dedups the NULL/root context without a
# sentinel. The two visit columns are bare nullable bigint (no DB FK), matching
# Claim#visit's nullable column.
class CreateEnliteratorLacunae < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_lacunae do |t|
      t.string   :tendable_type
      t.string   :tendable_id
      t.string   :facet
      t.string   :key                                    # the required term that is absent
      t.bigint   :context_id                             # NULL = root scope
      t.string   :diagnosis                              # defective_surrogate | silent | not_identified | undiagnosed
      t.text     :note                                   # the model's one-phrase justification
      t.string   :status, null: false, default: "open"   # open | closed
      t.string   :closed_reason                          # supplied | dismissed | not_identified_confirmed
      t.bigint   :detected_in_visit_id                   # prov: the visit that first opened it
      t.bigint   :closed_by_visit_id                     # the visit that supplied the value, on closure
      t.datetime :last_detected_at
      t.integer  :detections, null: false, default: 1
      t.timestamps
    end

    add_index :enliterator_lacunae, [ :tendable_type, :tendable_id ],
              name: "idx_enliterator_lacunae_on_tendable"
    add_index :enliterator_lacunae, :context_id
    add_index :enliterator_lacunae, [ :facet, :key ],
              name: "idx_enliterator_lacunae_on_facet_key"
    add_index :enliterator_lacunae, :status

    # One OPEN lacuna per (tendable, facet, key, context). nulls_not_distinct so a
    # NULL (root) context_id dedups like any other value (Postgres treats NULLs as
    # distinct otherwise). open_or_refresh guards application-side; this is a backstop.
    add_index :enliterator_lacunae,
              [ :tendable_type, :tendable_id, :facet, :key, :context_id ],
              unique: true, nulls_not_distinct: true, where: "status = 'open'",
              name: "idx_enliterator_lacunae_open"
  end
end
