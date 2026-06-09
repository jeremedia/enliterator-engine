class RenameStreamToFacet < ActiveRecord::Migration[8.1]
  # v0.12 — a tending "stream" is a descriptive FACET (Ranganathan's faceted
  # classification): the dimension a record is read along. With the quality-score
  # concept renamed to Measure (prior migration), "facet" is free for its true sense.
  def up
    rename_column :enliterator_visits, :stream, :facet
    rename_column :enliterator_suggestions, :stream, :facet
  end

  def down
    rename_column :enliterator_visits, :facet, :stream
    rename_column :enliterator_suggestions, :facet, :stream
  end
end
