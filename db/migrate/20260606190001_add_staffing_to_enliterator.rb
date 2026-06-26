# Staffing & Routing additions. Additive to v0.1.
# Per-Visit tier + escalation chain are the substrate every later capability reads
# (re-staffing, cost attribution, trust). Recorded from the first routing commit.
class AddStaffingToEnliterator < ActiveRecord::Migration[8.1]
  def change
    # enliterator_visits: tier + escalation chain.
    add_column :enliterator_visits, :tier, :string                        # alias used (capability tier)
    add_column :enliterator_visits, :escalated_from_id, :bigint           # self FK nullable — senior→junior link
    add_column :enliterator_visits, :escalation_step, :integer, null: false, default: 0
    add_column :enliterator_visits, :applied, :boolean, null: false, default: true # false for a junior visit whose recon was NOT applied

    add_index :enliterator_visits,
              [ :tendable_type, :tendable_id, :tier ],
              name: "idx_enliterator_visits_on_tendable_and_tier"

    add_foreign_key :enliterator_visits, :enliterator_visits, column: :escalated_from_id, on_delete: :nullify

    # enliterator_claims: tier that minted/last-updated the live claim.
    add_column :enliterator_claims, :tier, :string
  end
end
