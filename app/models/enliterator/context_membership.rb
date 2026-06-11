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
  end
end
