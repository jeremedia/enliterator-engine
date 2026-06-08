# v0.7: when a curator MAPS a proposed key to an existing canonical key (a synonym,
# not a gap), record the target as structured data — proposed_key -> mapped_to —
# so future tending can auto-route the synonym instead of re-proposing it.
class AddMappedToToEnliteratorSuggestions < ActiveRecord::Migration[8.1]
  def change
    add_column :enliterator_suggestions, :mapped_to, :string
  end
end
