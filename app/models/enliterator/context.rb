module Enliterator
  # A nested enliterated collection (v0.13) — a faceted LENS an item is read
  # through. An item belongs to the root collection and to any number of labeled
  # sub-contexts (via ContextMembership); each context carries its own facets +
  # vocabulary in the staffing policy (joined by `key`), INHERITING its ancestors'.
  # Claims/Visits are scoped per context and read cumulatively up the ancestry.
  #
  # THE ROOT RULE (design rule 1): NULL is the root scope. A root Context row (no
  # parent) exists only as the tree anchor for UI and membership — nothing ever
  # stamps its id on a Claim or Visit. Tending "at root" writes context_id: NULL,
  # which is also where all pre-v0.13 data already lives. Cumulative reads from a
  # child therefore use `context_id: [nil, *path_ids]`.
  #
  # (Not to be confused with the staffing Policy's `context_cap` — the LLM
  # context-WINDOW cap per tier. Unrelated concepts that share a word.)
  class Context < ApplicationRecord
    has_ancestry

    has_many :memberships, class_name: "Enliterator::ContextMembership", dependent: :destroy

    validates :key, presence: true, uniqueness: true,
                    format: { with: /\A[a-z0-9][a-z0-9\-]*\z/, message: "must be a lowercase slug" }
    validates :name, presence: true

    # Policy-resolution keys, root → self. Drives facet inheritance: the
    # effective facet set is the policy's declarations merged along this list.
    def path_keys
      path.pluck(:key)
    end

    # Claim/Visit scope ids for the CUMULATIVE read (root rule): NULL (the root
    # scope) plus every ancestor id plus self. `where(context_id: scope_ids)`
    # emits `IN (...) OR IS NULL`.
    def scope_ids
      [ nil, *path_ids ]
    end

    def self.find_by_key!(key)
      find_by!(key: key.to_s)
    end
  end
end
