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
      @running      = Enliterator::ConsidererRun.unfinished.order(:started_at).last
      Enliterator::ProposedTerm.refresh!                            # materialize pressure
      @terms        = scoped_terms                                  # pressure-ranked, current scope
      @canonical    = canonical_keys                                # legal map targets in this context
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
        stalled:       row.pulse_at.present? && row.pulse_at < Enliterator::ConsidererRun::STALL_AFTER.ago
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
          Enliterator::Suggestion.map_key!(key, to: target, note: note, context: current_context)
        else
          return redirect_to(suggestions_path, alert: "Unknown decision: #{params[:decision].inspect}.")
        end

      verb = params[:decision] == "map" ? "mapped \"#{key}\" → \"#{params[:mapped_to]}\"" : "#{params[:decision]}d \"#{key}\""
      redirect_to suggestions_path, notice: "#{verb} (#{n} record#{'s' if n != 1})."
    end

    private

    # The pressure-ranked queue, filtered to terms with pending proposals in the
    # CURRENT scope (pressure itself stays a global signal on ProposedTerm).
    def scoped_terms
      pending_keys = Enliterator::Suggestion.pending
                       .where(context_id: current_context&.id)
                       .distinct.pluck(:proposed_key)
      Enliterator::ProposedTerm.open.by_pressure.where(proposed_key: pending_keys)
    end

    # Every term in the current context's EFFECTIVE vocabulary (inherited + own,
    # code + approved) — the legal targets a synonym can map onto.
    def canonical_keys
      Enliterator.staffing.facets_for(current_context&.path_keys).keys
        .flat_map { |s| (Enliterator::Vocabulary.for(s, context: current_context) || {}).keys }.uniq.sort
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
