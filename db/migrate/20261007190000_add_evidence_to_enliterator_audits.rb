# frozen_string_literal: true

# v0.87: a verdict carries its evidence. `evidence` is the source passage the
# examiner quoted as deciding the verdict; `evidence_found` whether the engine
# found that quote in the source it examined (mechanically, "…"-tolerant);
# `evidence_basis` which kind of text the quote sits in (SourceBasis:
# document_text, catalog_record, reading_notes, ai_summary, …) — so a reader
# can tell a verdict grounded in the author's words from one grounded in the
# catalog's own notes.
#
# Nullable, no default: null means "examined without the evidence
# requirement" (pre-v0.87, or audit_evidence off) — never "no evidence found".
# Purely additive ⇒ byte-identical behavior.
class AddEvidenceToEnliteratorAudits < ActiveRecord::Migration[7.1]
  def change
    add_column :enliterator_audits, :evidence, :text
    add_column :enliterator_audits, :evidence_found, :boolean
    add_column :enliterator_audits, :evidence_basis, :string
  end
end
