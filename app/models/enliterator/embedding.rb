module Enliterator
  # A named vector for a host record. Multiple kinds per record (e.g. "primary",
  # "full_text") via the unique [embeddable_type, embeddable_id, kind] index.
  class Embedding < ApplicationRecord
    belongs_to :embeddable, polymorphic: true

    has_neighbors :embedding

    validates :kind, presence: true

    # Nearest embeddings to a raw vector, by cosine distance.
    # Returns Embedding rows (each carrying a `neighbor_distance` attribute),
    # ordered nearest-first.
    def self.nearest_to(vector, kind: "primary", limit: 5)
      where(kind: kind)
        .nearest_neighbors(:embedding, vector, distance: "cosine")
        .first(limit)
    end
  end
end
