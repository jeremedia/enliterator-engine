module Enliterator
  # Read-only status browser — the Report smoke alarm + the collection self-portrait
  # in the browser, with per-record drill-down into claims / visits / measures.
  class StatusController < ApplicationController
    def index
      @synopsis = Enliterator::Synopsis.build(since: params[:since].presence)
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

      # Browser detail wants the WHOLE record, across facets (literacy_state is
      # facet-scoped, for prompt context — not what a drill-down wants).
      @type   = params[:type]
      @claims = @record.enliterator_claims.live.order(:key)
      @visits = @record.enliterator_visits.order(created_at: :desc).limit(20)
      @measures = @record.enliterator_measures.each_with_object({}) { |f, h| h[f.name] = f.score }
    end
  end
end
