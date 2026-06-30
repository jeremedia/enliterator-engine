module Enliterator
  # The authority file (v0.51), mounted at /enliterator/vocabulary. One read-only action;
  # all the work lives in Enliterator::Authority. Adoption-gated PER CONTEXT — a context
  # that has never had a proposal renders the zero-state card, not an empty frame (and a
  # flat install with no proposals at all stays byte-identical: an empty page body).
  class AuthorityController < ApplicationController
    def index
      @adopted = Enliterator::Suggestion.where(context_id: current_context&.id).exists?
      return unless @adopted

      @overview = Enliterator::Authority.new(context: current_context).overview
    end

    # ---- curator corrections (v0.52) — write to the curator's OWN context (rule 4) ----

    # Re-point one variant's USE target onto a different preferred term (also the UI "split").
    def reroute
      key = params[:proposed_key].to_s
      to  = params[:to].to_s
      return redirect_to(vocabulary_path, alert: "Pick a variant and a target.") if key.blank? || to.blank?
      return redirect_to(vocabulary_path, alert: "“#{to}” is not a preferred term — pick a legal target.") unless legal_target?(to)
      apply(Enliterator::Suggestion.reroute_key!(key, to: to, context: current_context),
            key, "re-routed “#{key}” → “#{to}”")
    end

    # Promote a mapped/rejected variant to a preferred term (it joins the effective vocabulary).
    def promote
      key = params[:proposed_key].to_s
      return redirect_to(vocabulary_path, alert: "No term given.") if key.blank?
      apply(Enliterator::Suggestion.promote_key!(key, context: current_context),
            key, "promoted “#{key}” to a preferred term")
    end

    # Demote a preferred term to mapped (onto a target) or rejected.
    def demote
      key       = params[:proposed_key].to_s
      to_status = params[:to_status].to_s
      to        = params[:to].presence
      return redirect_to(vocabulary_path, alert: "No term given.") if key.blank?
      return redirect_to(vocabulary_path, alert: "Demote to “mapped” or “rejected”.") unless %w[mapped rejected].include?(to_status)
      if to_status == "mapped"
        return redirect_to(vocabulary_path, alert: "Demote-to-mapped needs a target.") if to.blank?
        return redirect_to(vocabulary_path, alert: "“#{to}” is not a preferred term.") unless legal_target?(to)
      end
      apply(Enliterator::Suggestion.demote_key!(key, to_status: to_status, to: to, context: current_context),
            key, "demoted “#{key}” to #{to_status}")
    end

    # Fold an entire ring (from) onto another preferred term (into).
    def merge
      from = params[:from].to_s
      into = params[:into].to_s
      return redirect_to(vocabulary_path, alert: "Pick both terms.") if from.blank? || into.blank?
      return redirect_to(vocabulary_path, alert: "Cannot merge a term into itself.") if from == into
      return redirect_to(vocabulary_path, alert: "“#{into}” is not a preferred term.") unless legal_target?(into)
      apply(Enliterator::Suggestion.merge_keys!(from: from, into: into, context: current_context),
            from, "merged “#{from}” → “#{into}”", also_settle: into)
    end

    # Peel a named subset of a term's variants onto a different preferred term (batch split).
    def split
      key  = params[:proposed_key].to_s
      to   = params[:to].to_s
      move = Array(params[:move]).reject(&:blank?)
      return redirect_to(vocabulary_path, alert: "Pick variants and a target.") if key.blank? || to.blank? || move.empty?
      return redirect_to(vocabulary_path, alert: "“#{to}” is not a preferred term.") unless legal_target?(to)
      apply(Enliterator::Suggestion.split_key!(key, move: move, to: to, context: current_context),
            to, "split #{move.size} variant#{'s' if move.size != 1} → “#{to}”")
    end

    private

    # A legal correction target is a preferred term in this context's effective vocabulary.
    def legal_target?(term)
      Enliterator::Authority.new(context: current_context).canonical_keys.include?(term)
    end

    # Shared tail: alert on a 0-row no-op (rule 3 — never a green success on nothing); on a real
    # change, retire the now-stale governance signals for the settled key(s) and confirm.
    def apply(n, key, verb, also_settle: nil)
      if n.zero?
        redirect_to vocabulary_path, alert: "Nothing to change for “#{key}” in this context (already so, or wrong context?)."
      else
        Enliterator::ProposedTerm.settle!(key)
        Enliterator::ProposedTerm.settle!(also_settle) if also_settle
        redirect_to vocabulary_path, notice: "#{verb} (#{n} row#{'s' if n != 1})."
      end
    end
  end
end
