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
  end
end
