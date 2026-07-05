# v0.57 charter tests: the dummy's ONE-ROW collection tendable (the record the
# charter's told identity lives on). Kept separate from Book (the topology
# whole) so charter specs never entangle with topology specs.
class CreateLibraries < ActiveRecord::Migration[7.1]
  def change
    create_table :libraries do |t|
      t.string :name
      t.timestamps
    end
  end
end
