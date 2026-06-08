module Enliterator
  # Suggestion review — the governed-vocabulary queue. The model proposes claim keys
  # a stream's contract doesn't cover; a curator renders a verdict per proposed_key:
  # APPROVE (a real gap — surface the contract diff to add), MAP (a synonym of an
  # existing key — record the canonical target), or REJECT. The ontology tends itself.
  class SuggestionsController < ApplicationController
    def index
      @gaps         = Enliterator::Suggestion.gaps                 # pending, demand-ranked
      @streams_for  = pending_streams_by_key                       # proposed_key => [streams]
      @canonical    = canonical_keys                               # all existing contract keys (map targets)
      @additions    = Enliterator::Suggestion.contract_additions   # {stream => [approved keys]}
      @synonyms     = Enliterator::Suggestion.synonyms             # [{stream, proposed_key, mapped_to}]
      @pending      = Enliterator::Suggestion.pending.count
      @resolved     = Enliterator::Suggestion.where.not(status: "pending").count
    end

    def verdict
      key  = params[:proposed_key].to_s
      note = params[:note].presence
      if key.blank?
        return redirect_to(suggestions_path, alert: "No proposed_key given.")
      end

      n =
        case params[:decision]
        when "approve" then Enliterator::Suggestion.approve_key!(key, note: note)
        when "reject"  then Enliterator::Suggestion.reject_key!(key, note: note)
        when "map"
          target = params[:mapped_to].to_s
          return redirect_to(suggestions_path, alert: "Pick a key to map \"#{key}\" onto.") if target.blank?
          Enliterator::Suggestion.map_key!(key, to: target, note: note)
        else
          return redirect_to(suggestions_path, alert: "Unknown decision: #{params[:decision].inspect}.")
        end

      verb = params[:decision] == "map" ? "mapped \"#{key}\" → \"#{params[:mapped_to]}\"" : "#{params[:decision]}d \"#{key}\""
      redirect_to suggestions_path, notice: "#{verb} (#{n} record#{'s' if n != 1})."
    end

    private

    def pending_streams_by_key
      Enliterator::Suggestion.pending.distinct.pluck(:proposed_key, :stream)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last).compact.uniq.sort }
    end

    # Every claim key that already exists in any stream's contract — the legal
    # targets a synonym can map onto.
    def canonical_keys
      policy = Enliterator.staffing
      policy.assignments.keys.flat_map { |s| (policy.keys_for(s) || {}).keys }.uniq.sort
    end
  end
end
