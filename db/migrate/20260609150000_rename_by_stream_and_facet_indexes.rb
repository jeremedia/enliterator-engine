class RenameByStreamAndFacetIndexes < ActiveRecord::Migration[8.1]
  # v0.12 — finish the stream→facet rename at the schema level: the proposed-term
  # pressure aggregate's per-stream breakdown column, and the index names that
  # rename_column left pointing at the old word (cosmetic, but kept legible).
  def up
    rename_column :enliterator_proposed_terms, :by_stream, :by_facet
    rename_index :enliterator_suggestions, "idx_enliterator_suggestions_on_stream_and_status", "idx_enliterator_suggestions_on_facet_and_status"
    rename_index :enliterator_visits, "idx_enliterator_visits_on_tendable_and_stream", "idx_enliterator_visits_on_tendable_and_facet"
  end

  def down
    rename_column :enliterator_proposed_terms, :by_facet, :by_stream
    rename_index :enliterator_suggestions, "idx_enliterator_suggestions_on_facet_and_status", "idx_enliterator_suggestions_on_stream_and_status"
    rename_index :enliterator_visits, "idx_enliterator_visits_on_tendable_and_facet", "idx_enliterator_visits_on_tendable_and_stream"
  end
end
