# enliterator_embeddings — named vectors per record (PROV-agnostic corpus context).
# Polymorphic *_id columns are :string to support both bigint and uuid hosts.
class CreateEnliteratorEmbeddings < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_embeddings do |t|
      t.string :embeddable_type, null: false
      t.string :embeddable_id, null: false
      t.string :kind, null: false, default: "primary"
      # NOTE: 1536 is Enliterator.configuration.default_embedding_dimensions (OpenAI
      # text-embedding-3-small). Hardcoded here because migrations must be frozen at
      # author time; change the column type in a host migration if you switch models.
      t.vector :embedding, limit: 1536
      t.integer :dimensions
      t.string :model
      t.string :content_hash
      t.timestamps
    end

    add_index :enliterator_embeddings,
              [ :embeddable_type, :embeddable_id, :kind ],
              unique: true,
              name: "idx_enliterator_embeddings_on_embeddable_and_kind"

    add_index :enliterator_embeddings, :embedding,
              using: :hnsw,
              opclass: :vector_cosine_ops,
              name: "idx_enliterator_embeddings_on_embedding_hnsw"
  end
end
