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

    # v0.78: the READ view — what a patron, the desk, or a browse surface sees
    # "in" this context: the cumulative scope above PLUS every descendant's own
    # scope. The v0.13 root rule already made the root view the unfiltered
    # union; this generalizes it so a PARENT context reads its subtree instead
    # of only root-scope rows (a parent that holds no records directly, like a
    # federation anchor, read as empty). For a leaf, descendant_ids is [] and
    # this equals scope_ids exactly — leaf reads are byte-identical.
    #
    # READ surfaces only. Tending inputs, the effective vocabulary, suggestion
    # gaps and the planner keep scope_ids: declaration location = tending
    # scope (rule 2), and a sibling's claims never leak into a sibling's
    # tend (rule 4 — siblings still cannot see each other here either; only an
    # ANCESTOR sees its descendants).
    def read_scope_ids
      [ *scope_ids, *descendant_ids ]
    end

    def self.find_by_key!(key)
      find_by!(key: key.to_s)
    end
  end
end
