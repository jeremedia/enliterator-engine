# v0.9: when tending re-proposes a key the curator already mapped or rejected, we
# SUPPRESS the re-file (the queue stops re-litigating) but bump this counter — so
# "the model keeps wanting a key you dismissed" stays visible (the overruling
# signal) without flooding the queue. Preserved across ProposedTerm.refresh!.
class AddPostVerdictAttemptsToEnliteratorProposedTerms < ActiveRecord::Migration[8.1]
  def change
    add_column :enliterator_proposed_terms, :post_verdict_attempts, :integer, null: false, default: 0
  end
end
