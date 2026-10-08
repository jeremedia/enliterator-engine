# frozen_string_literal: true

# v0.90: where THIS database's enliteration came from. An import records an
# `import` event (the archive's exported_from label and export time); a
# curator's `rake enliterator:declare_authority` records an `authority`
# event. The latest event decides whether this deployment takes curation
# writes when `config.curation_writes` is unset: a copy (latest = import)
# refuses, the authoring deployment (no events, or latest = authority) does
# not. TARGET-LOCAL (Portability): never exported, never truncated, never
# loaded — it describes this database, not the enliteration.
class CreateEnliteratorLineageEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :enliterator_lineage_events do |t|
      t.string   :kind, null: false            # import | authority
      t.string   :source_label                 # import: the archive's exported_from
      t.datetime :source_exported_at           # import: when the archive was written
      t.string   :note
      t.datetime :created_at, null: false
    end
    add_index :enliterator_lineage_events, :created_at
  end
end
