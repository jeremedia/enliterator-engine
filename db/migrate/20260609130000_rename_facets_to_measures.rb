class RenameFacetsToMeasures < ActiveRecord::Migration[8.1]
  # v0.12 — free the word "facet" for its true meaning. The quality-score concept
  # (a named score + signals per record, e.g. completeness) is a MEASURE, not a
  # classification facet; renaming it lets a tending stream become a "facet"
  # (Ranganathan) without collision. rename_table carries the unique index.
  def up
    rename_table :enliterator_facets, :enliterator_measures
  end

  def down
    rename_table :enliterator_measures, :enliterator_facets
  end
end
