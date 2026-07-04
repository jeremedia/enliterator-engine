# v0.56 topology tests: a dummy WHOLE (Book) grouping Widgets via widgets.book_id.
# Nullable FK — every pre-existing Widget spec is untouched (nil = no whole).
class CreateBooksAndWidgetBook < ActiveRecord::Migration[7.1]
  def change
    create_table :books do |t|
      t.string :slug
      t.string :title
      t.timestamps
    end
    add_column :widgets, :book_id, :bigint
    add_index :widgets, :book_id
  end
end
