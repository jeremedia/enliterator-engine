module Enliterator
  # A named vector for a host record. Multiple kinds per record (e.g. "primary",
  # "full_text") via the unique [embeddable_type, embeddable_id, kind] index.
  class Embedding < ApplicationRecord
    belongs_to :embeddable, polymorphic: true

    has_neighbors :embedding

    validates :kind, presence: true

    # v0.24: the retrieval/browse pool within a context — the context's MEMBERS
    # (Conversation's v0.13 pattern, extracted so Chat retrieval and the
    # Catalog read the same pool). nil context = the whole collection (root).
    scope :in_context, ->(context) {
      next all if context.nil?
      where(
        Enliterator::ContextMembership.member_exists(
          context,
          type_sql: "enliterator_embeddings.embeddable_type",
          id_sql:   "enliterator_embeddings.embeddable_id"
        ).arel.exists
      )
    }

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
