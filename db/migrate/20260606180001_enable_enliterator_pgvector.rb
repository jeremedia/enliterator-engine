# Enable pgvector before any vector columns are created.
# The engine owns its extension enablement.
class EnableEnliteratorPgvector < ActiveRecord::Migration[8.1]
  def change
    enable_extension "vector" unless extension_enabled?("vector")
  end
end
