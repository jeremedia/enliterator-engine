# Host-app table for the dummy. Widget is the Tendable host model used by the
# engine's RSpec suite. Bigint primary key (the common host case); polymorphic
# Enliterator tables store its id as a string so they also support UUID hosts.
class CreateWidgets < ActiveRecord::Migration[8.1]
  def change
    create_table :widgets do |t|
      t.string :title
      t.text :body

      t.timestamps
    end
  end
end
