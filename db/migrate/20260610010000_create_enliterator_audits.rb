# v0.18: the audit register — quality review for the claim store. One row per
# examination of one claim, by the LLM examiner or by a human; multiple audits
# per claim are the point (the human ANCHORS the examiner). Append-only by
# convention: accuracy is a process rate and audits never age out of it.
#
# claim FK cascades: an audit without its claim is uninterpretable (facet and
# tier resolve THROUGH the claim) — the named consequence is that destroying
# host records removes audit history and can shift the rate.
class CreateEnliteratorAudits < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_audits do |t|
      t.references :claim, null: false,
                   foreign_key: { to_table: :enliterator_claims, on_delete: :cascade }
      t.string  :verdict, null: false      # supported | unsupported | contradicted | unverifiable
      t.text    :rationale
      t.jsonb   :corrected_value, default: {}   # the examiner's PROPOSAL (pre-fills the human form)
      t.references :corrected_claim, null: true, # the human correction actually minted
                   foreign_key: { to_table: :enliterator_claims, on_delete: :nullify }
      t.string  :source, null: false       # examiner | human — who rendered this verdict
      t.string  :auditor                   # "tier:model" or the human's note (attributed_to convention)
      t.float   :confidence
      t.references :heartbeat, null: true,
                   foreign_key: { to_table: :enliterator_heartbeats, on_delete: :nullify }
      # The exact source the verdict was rendered against — lets the Review
      # surface flag "source changed since examination" for pennies.
      t.string  :source_digest
      t.integer :source_chars
      t.boolean :source_truncated, default: false
      t.timestamps
    end

    add_column :enliterator_heartbeats, :audits, :jsonb, default: {}
  end
end
