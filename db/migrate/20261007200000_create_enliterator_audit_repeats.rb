# frozen_string_literal: true

# v0.88: instrument agreement. A repeat is the examiner asked again, under the
# same configuration, about a claim whose source has not changed since the
# original verdict. It is NOT an audit: it never enters accuracy, the sampler,
# or the review queue — it measures the instrument, not the claim store.
class CreateEnliteratorAuditRepeats < ActiveRecord::Migration[7.1]
  def change
    create_table :enliterator_audit_repeats do |t|
      t.references :audit, null: false, foreign_key: { to_table: :enliterator_audits, on_delete: :cascade },
                           index: true
      t.references :heartbeat, foreign_key: { to_table: :enliterator_heartbeats, on_delete: :nullify }
      t.string  :facet, null: false
      t.string  :verdict, null: false       # the repeat's verdict
      t.boolean :agrees, null: false        # == the original audit's verdict
      t.boolean :evidence_mode, null: false # audit_evidence on (v0.87) — same instrument both times
      t.string  :auditor
      t.datetime :created_at, null: false
    end
    add_index :enliterator_audit_repeats, [ :facet, :created_at ]
  end
end
