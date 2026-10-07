module Enliterator
  # An item's membership in a Context (v0.13). Many-to-many and polymorphic: a
  # record lives in the root collection implicitly (root rule — no membership row
  # needed) and in any number of labeled sub-contexts explicitly. Membership is
  # what scopes context tending: `tend_context` walks a context's members, and
  # neighbor retrieval within a context is restricted to fellow members.
  class ContextMembership < ApplicationRecord
    belongs_to :context, class_name: "Enliterator::Context"
    belongs_to :member, polymorphic: true

    validates :member_id, uniqueness: { scope: [ :context_id, :member_type ] }

    # v0.24: the membership EXISTS predicate, generalized — "this outer row's
    # record is a member of +context+". type_sql/id_sql are STATIC column
    # literals supplied by engine code (never user input). Use as:
    #   pool.where(ContextMembership.member_exists(ctx, type_sql: "t.c", id_sql: "t.c").arel.exists)
    def self.member_exists(context, type_sql:, id_sql:)
      where(context_id: context.id)
        .where("enliterator_context_memberships.member_type = #{type_sql}")
        .where("enliterator_context_memberships.member_id = #{id_sql}")
    end

    # v0.78: the READ form — "a member of +context+ or of any context beneath
    # it". A parent that holds no records directly (HSDL's `hsdl` anchor) read
    # as empty through member_exists; its members are its subtree's. EXISTS
    # dedups a record seated in two children. For a leaf, subtree_ids == [id]
    # and Rails renders `context_id = id` — the SQL is byte-identical to
    # member_exists. Tending, planning, pulse and topology keep member_exists:
    # a context tends, plans and owns only its OWN holdings.
    def self.member_exists_in_subtree(context, type_sql:, id_sql:)
      where(context_id: context.subtree_ids)
        .where("enliterator_context_memberships.member_type = #{type_sql}")
        .where("enliterator_context_memberships.member_id = #{id_sql}")
    end

    # Distinct records seated anywhere in +context+'s subtree (a record in two
    # children counts once) — the honest "N member records" for a read view.
    def self.subtree_member_count(context)
      pairs = where(context_id: context.subtree_ids).select(:member_type, :member_id).distinct
      # v0.83: under an audience scope, a context holds only what this reader may see.
      pairs = Enliterator::MemberScope.restrict(pairs, type_sql: "enliterator_context_memberships.member_type",
                                                      id_sql: "enliterator_context_memberships.member_id")
      unscoped.from(pairs, :pairs).count
    end
  end
end
