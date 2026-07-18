# frozen_string_literal: true

# v0.61.1: `re_derived` records whether a Visit actually used the RE-DERIVE prompt
# (distrust prior claims, re-read current text) rather than the compounding/inherit
# one — true for a deliberate "revalidate" drain visit AND for an organic
# "source_change" re-derive under the flag. The revalidation gauge keys on THIS, not
# on reason == "revalidate", so a chapter freshened by a real source edit is credited
# (not redundantly re-drained). Nullable: every pre-v0.61.1 visit reads as
# not-re-derived. Purely additive ⇒ byte-identical behavior.
class AddReDerivedToEnliteratorVisits < ActiveRecord::Migration[7.1]
  def change
    add_column :enliterator_visits, :re_derived, :boolean
  end
end
