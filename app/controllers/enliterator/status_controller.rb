module Enliterator
  # Read-only status browser — the Report smoke alarm + the collection self-portrait
  # in the browser, with per-record drill-down into claims / visits / measures.
  class StatusController < ApplicationController
    def index
      # v0.13: the portrait of the SELECTED context (root = the whole collection).
      @synopsis = Enliterator::Synopsis.build(since: params[:since].presence, context: current_context)
      @children = current_context ? current_context.children.order(:name) : Enliterator::Context.roots.order(:name)

      # v0.15: the next-cycle preview — GATED behind adoption (any ledger row).
      # v0.20: PREPARED, not censused — the preview reads the last cycle's
      # `planned` jsonb (with its as-of stamp) instead of re-walking 300K host
      # rows per page view. The live plan still runs where it is authoritative:
      # open! re-plans when a beat starts. Absent any ledger row, the page
      # stays byte-identical to v0.14.
      @last_heartbeat = Enliterator::Heartbeat.order(:started_at).last
      @heartbeat_plan = @last_heartbeat ? Enliterator::Heartbeat::PreparedPlan.new(@last_heartbeat) : nil

      # v0.18: the accuracy panel — gated on any audit existing.
      if (@audit_adopted = Enliterator::Audit.exists?)
        @audit_accuracy  = Enliterator::Audit.accuracy
        @audit_agreement = Enliterator::Audit.anchor_agreement
        @audit_corrected = Enliterator::Audit.corrected_count
        @examiner_down   = @last_heartbeat&.audits&.key?("skipped_null_adapter")
      end

      # v0.17: the conservation report — gated the same way (any survey ever).
      # v0.20: the numbers come PREPARED (Condition.report, cached against the
      # latest cycle); treatments merge in LIVE — a curator's writes show at once.
      if (@condition_adopted = Enliterator::Condition.adopted?)
        @condition = Enliterator::Condition.report.merge(
          treatments: Enliterator::Treatment.all.index_by(&:signature)
        )
      end

      # v0.46: the gaps rollup — gated on any open lacuna existing (adoption is
      # global, like audit/condition; the data is scoped to the selected context).
      # CORE caveat: until the diagnosis layer (v0.46.1) ships, every diagnosis is
      # `undiagnosed`, so the rollup groups by facet (a diagnosis distribution
      # can't exist yet). open-lacunae counts are LIVE (vs the prepared frontier).
      if (@lacunae_adopted = Enliterator::Lacuna.open.exists?)
        scope = Enliterator::Lacuna.open
        scope = scope.where(context_id: current_context.id) if current_context
        @lacunae_total       = scope.count
        @lacunae_by_facet    = scope.group(:facet).count.sort_by { |_, n| -n }
        @lacunae_by_diagnosis = scope.group(:diagnosis).count.reject { |d, _| d == "undiagnosed" }
                                     .sort_by { |_, n| -n }
      end
    end

    def show
      klass = params[:type].to_s.safe_constantize
      # Allow-list: never instantiate an arbitrary class named in a URL — only
      # the host models that mounted Tendable, plus the engine's own Part
      # (v0.25: an analytical entry deserves an entry page too).
      unless Enliterator.tendable_type?(klass)
        return render(:not_found, status: :not_found)
      end

      @record = klass.find_by(id: params[:id]) # nil (not raise) on miss
      return render(:not_found, status: :not_found) if @record.nil?

      # Browser detail wants the WHOLE record, across facets AND contexts
      # (literacy_state is facet-scoped, for prompt context — not a drill-down).
      # Claims/visits carry their context so the view can label each lens.
      @type   = params[:type]
      @claims = @record.enliterator_claims.live.includes(:context).order(:key)
      # v0.46: the record's open known-unknowns (the negative space of its claims).
      # The panel renders only when present, so an unadopted host stays byte-identical.
      @lacunae = @record.enliterator_lacunae.open.includes(:context).order(:facet, :key)
      @visits = @record.enliterator_visits.includes(:context).order(created_at: :desc).limit(20)
      @measures = @record.enliterator_measures.each_with_object({}) { |f, h| h[f.name] = f.score }
      @contexts = @record.respond_to?(:enliterator_contexts) ? @record.enliterator_contexts.order(:name) : []
      # v0.14: understanding over time — only facets with >1 applied visit get a
      # timeline (a single visit has no trajectory; the section is absent).
      @trajectories = Enliterator::Trajectory.for(@record, last: 6)
                        .select { |line| line[:steps].size > 1 }
    end
  end
end
