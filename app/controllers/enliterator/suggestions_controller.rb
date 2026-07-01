module Enliterator
  # Suggestion review — the governed-vocabulary queue (authority control). The model
  # proposes terms a facet's vocabulary doesn't cover; a curator renders a verdict
  # per proposed_key: APPROVE (a real gap), MAP (a USE/UF synonym of an existing
  # term), or REJECT. The ontology tends itself.
  #
  # v0.13: governance is a WRITE surface, so the queue shows the CURRENT CONTEXT'S
  # OWN pending proposals (what a verdict here would actually resolve — rule 4:
  # verdicts write to their own context). Root shows the root-scope (NULL) queue —
  # the entire pre-v0.13 universe, so flat installs are unchanged.
  class SuggestionsController < ApplicationController
    def index
      Enliterator::ConsidererRun.reap_orphans!
      @running      = Enliterator::ConsidererRun.unfinished
                        .where("started_at > ?", Enliterator::ConsidererRun::OVERLAP_WINDOW.ago)
                        .order(:started_at).last
      Enliterator::ProposedTerm.refresh!                            # materialize pressure
      @pending_keys = pending_keys                                  # current-scope pending proposed keys
      @terms        = Enliterator::ProposedTerm.open.by_pressure.where(proposed_key: @pending_keys)
      @vocab        = effective_vocabulary                          # {term => description} across facets
      @canonical    = @vocab.keys.sort                              # legal map targets in this context
      # v0.54: what a reviewer needs to actually decide — the FULL per-record evidence for
      # each key (every rationale + example, no dead-end truncation), and for a map
      # recommendation, what already lives under the suggested target (its definition + the
      # variants folded onto it) so the reviewer can judge the fit.
      @evidence        = full_evidence(@pending_keys)
      @target_variants = target_variants(@terms)
      # v0.50: the auto-apply floor, so the Map dropdown only PRE-FILLS the considerer's
      # recommended target when the considerer was confident enough to have auto-applied it
      # itself. Below the floor the rec is shown but NOT pre-selected — clicking Map then
      # ratifies a deliberate choice, not a guess the considerer declined. `|| 0.75` mirrors
      # the considerer's own guard (considerer.rb), since the accessor is a bare attr a host
      # could nil (and `>= nil` raises).
      @min_conf     = Enliterator.configuration.considerer_min_confidence || 0.75
      @additions    = Enliterator::Suggestion.where(context_id: current_context&.id).contract_additions
      @synonyms     = Enliterator::Suggestion.where(context_id: current_context&.id).synonyms
      @pending      = Enliterator::Suggestion.pending.where(context_id: current_context&.id).count
      @resolved     = Enliterator::Suggestion.where.not(status: "pending").where(context_id: current_context&.id).count
      @reproposed   = reproposed_terms                             # v0.9: model re-asked after a verdict
      @verdicts     = verdicts_for(@reproposed)                    # {proposed_key => {status:, mapped_to:}}
    end

    # Open an async ConsidererRun and redirect immediately — no more blocking.
    # The monitor on the index page polls /suggestions/consider/pulse/:id until done.
    def consider
      run = Enliterator::ConsidererRun.open!(context: current_context)
      run.execute_async!
      redirect_to suggestions_path, notice: "Considering… (run ##{run.id})"
    rescue Enliterator::ConsidererRun::Overlap => e
      redirect_to suggestions_path, alert: e.message
    end

    # JSON pulse for the live monitor. Mirrors heartbeat#pulse exactly.
    def consider_pulse
      row = Enliterator::ConsidererRun.find(params[:id])
      row.reap! if row.orphaned?
      render json: {
        id:            row.id,
        status:        row.status,
        phase:         row.phase,
        planned_count: row.planned_count,
        done_count:    row.done_count,
        finished:      row.finished?,
        error:         row.error,
        summary:       row.finished? ? row.summary : nil,
        stalled:       !row.finished? && (row.pulse_at || row.started_at) < Enliterator::ConsidererRun::STALL_AFTER.ago
      }
    end

    def verdict
      key  = params[:proposed_key].to_s
      note = params[:note].presence
      if key.blank?
        return redirect_to(suggestions_path, alert: "No proposed_key given.")
      end

      n =
        case params[:decision]
        when "approve" then Enliterator::Suggestion.approve_key!(key, note: note, context: current_context)
        when "reject"  then Enliterator::Suggestion.reject_key!(key, note: note, context: current_context)
        when "map"
          target = params[:mapped_to].to_s
          return redirect_to(suggestions_path, alert: "Pick a key to map \"#{key}\" onto.") if target.blank?
          # v0.53: the map target is now a free-text type-ahead (datalist), so validate it
          # against the effective vocabulary — a typo'd target would write a USE-reference
          # pointing nowhere (rule 3). @canonical isn't set on this action; recompute.
          unless canonical_keys.include?(target)
            return redirect_to(suggestions_path, alert: "\"#{target}\" is not a preferred term — pick one from the list.")
          end
          Enliterator::Suggestion.map_key!(key, to: target, note: note, context: current_context)
        else
          return redirect_to(suggestions_path, alert: "Unknown decision: #{params[:decision].inspect}.")
        end

      verb = params[:decision] == "map" ? "mapped \"#{key}\" → \"#{params[:mapped_to]}\"" : "#{params[:decision]}d \"#{key}\""
      # v0.50: a 0-row update is a no-op (key already resolved, wrong context, or a stale
      # double-submit) — surface it as an ALERT, not a green success notice (rule 3: no
      # silent failure). `update_all` returns the affected-row count.
      if n.zero?
        redirect_to suggestions_path, alert: "No pending \"#{key}\" in this context — nothing to #{params[:decision]} (already resolved, or wrong context?)."
      else
        redirect_to suggestions_path, notice: "#{verb} (#{n} record#{'s' if n != 1})."
      end
    end

    private

    # The current-scope pending proposed keys (the queue's membership).
    def pending_keys
      Enliterator::Suggestion.pending.where(context_id: current_context&.id).distinct.pluck(:proposed_key)
    end

    # The current context's EFFECTIVE vocabulary WITH descriptions (inherited + own, code +
    # approved): {term => description}. First definition per term wins (code before approved).
    def effective_vocabulary
      Enliterator.staffing.facets_for(current_context&.path_keys).keys.each_with_object({}) do |facet, h|
        (Enliterator::Vocabulary.for(facet, context: current_context) || {}).each { |term, desc| h[term] ||= desc }
      end
    end

    # Legal map targets — the effective vocabulary's terms. Used by #verdict's target guard.
    def canonical_keys
      effective_vocabulary.keys.sort
    end

    # v0.54: every record's rationale + example for each pending key (deduped, capped) — the
    # full evidence a reviewer reads to decide, behind the card's Evidence expander.
    # {proposed_key => [{rationale:, example:}, ...]}.
    def full_evidence(keys)
      return {} if keys.empty?
      Enliterator::Suggestion.where(context_id: current_context&.id, proposed_key: keys)
        .order(:id).pluck(:proposed_key, :rationale, :example_value)
        .group_by(&:first)
        .transform_values { |rows| rows.map { |_, r, e| { rationale: r, example: e } }.uniq.first(12) }
    end

    # v0.54: what already maps onto each RECOMMENDED map target — so a reviewer can see the
    # target's ring before folding onto it. {target => [variant proposed_key, ...]}.
    def target_variants(terms)
      targets = terms.filter_map { |t| t.recommended_map_to.presence if t.recommended_decision == "map" }.uniq
      return {} if targets.empty?
      Enliterator::Suggestion.where(context_id: current_context&.id, status: "mapped", mapped_to: targets)
        .pluck(:mapped_to, :proposed_key).group_by(&:first).transform_values { |rows| rows.map(&:last).uniq.sort }
    end

    # Terms the model has re-proposed AFTER a verdict — the suppressed re-files
    # (post_verdict_attempts), ranked by how insistent the model is. This is the
    # "model overruling the curator" signal: the place to reconsider a verdict.
    def reproposed_terms
      Enliterator::ProposedTerm.where("post_verdict_attempts > 0").order(post_verdict_attempts: :desc)
    end

    # Most-recent verdict per re-proposed key (the thing the model is pushing back on).
    def verdicts_for(terms)
      keys = terms.map(&:proposed_key)
      return {} if keys.empty?
      Enliterator::Suggestion.where.not(status: "pending").where(proposed_key: keys)
        .order(:updated_at) # last write per key wins → newest verdict
        .each_with_object({}) { |s, h| h[s.proposed_key] = { status: s.status, mapped_to: s.mapped_to } }
    end
  end
end
