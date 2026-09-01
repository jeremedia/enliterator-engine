# frozen_string_literal: true

# v0.75: the warrant paper — the checking-act made durable, dated against its
# terrain. `source_digest` is the MD5 of the FULL `enliterator_text(facet:)`
# this visit's reader was given (matching the audit convention: digest over the
# whole text, ceilings recorded separately); `source_chars` rides along as the
# extraction diagnostic (the v0.72 replay found 81/100 surrogates cut
# mid-sentence — a per-visit chars series makes extraction changes visible).
#
# Nullable, no default: null means "pre-v0.75 — what this reader saw is
# unknowable", exactly the re_derived precedent. Purely additive ⇒
# byte-identical behavior; `warrant_stale?` reads null as UNKNOWN, never fresh,
# never stale. No index — nothing queries by digest alone; comparisons ride
# idx_enliterator_visits_on_tendable_and_facet.
class AddSourceDigestToEnliteratorVisits < ActiveRecord::Migration[7.1]
  def change
    add_column :enliterator_visits, :source_digest, :string
    add_column :enliterator_visits, :source_chars, :integer
  end
end
