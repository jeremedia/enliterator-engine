module Enliterator
  # Read-only status browser — the Report smoke alarm + the collection self-portrait
  # in the browser, with per-record drill-down into claims / visits / measures.
  class StatusController < ApplicationController
    def index
      # v0.13: the portrait of the SELECTED context (root = the whole collection).
      @synopsis = Enliterator::Synopsis.build(since: params[:since].presence, context: current_context)
      @children = current_context ? current_context.children.order(:name) : Enliterator::Context.roots.order(:name)

      # v0.15: the next-cycle preview — GATED behind adoption (any ledger row).
      # The planner's count queries must not slow a host's Status page that has
      # never run a heartbeat: absent, the page is byte-identical to v0.14.
      @last_heartbeat = Enliterator::Heartbeat.order(:started_at).last
      @heartbeat_plan = @last_heartbeat ? Enliterator::Heartbeat.plan : nil
    end

    def show
      klass = params[:type].to_s.safe_constantize
      # Allow-list: never instantiate an arbitrary class named in a URL — only the
      # host models that actually mounted Tendable.
      unless klass && Enliterator.tendable_models.include?(klass)
        return render(:not_found, status: :not_found)
      end

      @record = klass.find_by(id: params[:id]) # nil (not raise) on miss
      return render(:not_found, status: :not_found) if @record.nil?

      # Browser detail wants the WHOLE record, across facets AND contexts
      # (literacy_state is facet-scoped, for prompt context — not a drill-down).
      # Claims/visits carry their context so the view can label each lens.
      @type   = params[:type]
      @claims = @record.enliterator_claims.live.includes(:context).order(:key)
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
