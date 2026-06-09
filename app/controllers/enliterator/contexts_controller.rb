module Enliterator
  # The context tree (v0.13) — nested enliterated collections. Each node shows its
  # own facets (rule 2: what tends HERE), member count, and context-scoped
  # claim/visit counts. Read-only; the tree itself is seeded by the host.
  class ContextsController < ApplicationController
    def index
      @rows   = tree_rows                 # [[context, depth], ...] in tree order
      @stats  = context_stats
      @policy = Enliterator.staffing
    end

    private

    # The whole tree flattened depth-first: [[Context, depth], ...].
    def tree_rows
      Enliterator::Context.roots.order(:name).flat_map { |root| flatten(root.subtree.arrange) }
    end

    def flatten(arranged, depth = 0)
      arranged.flat_map { |node, children| [ [ node, depth ] ] + flatten(children, depth + 1) }
    end

    # One pass per table, grouped by context_id — cheap regardless of tree size.
    def context_stats
      {
        members: Enliterator::ContextMembership.group(:context_id).count,
        claims:  Enliterator::Claim.live.group(:context_id).count,
        visits:  Enliterator::Visit.where(status: "succeeded", applied: true).group(:context_id).count
      }
    end
  end
end
