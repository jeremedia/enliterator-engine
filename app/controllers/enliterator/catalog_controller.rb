module Enliterator
  # The catalog (v0.24) — browse and search the enliterated holdings. One
  # action, modes by params: no params = the browse landing (stats, subject
  # headings, recently tended, the grid); ?q= = search by meaning; ?key=&value=
  # = the subject filter; ?type= and ?page= narrow and window the grid. All
  # the work lives in Enliterator::Catalog; this stays thin.
  class CatalogController < ApplicationController
    def index
      @type         = safe_type
      @unknown_type = params[:type].presence if params[:type].present? && @type.nil?
      @catalog      = Enliterator::Catalog.new(context: current_context, type: @type)
      @overview     = @catalog.overview

      if params[:q].present?
        @q      = params[:q].to_s
        @search = @catalog.search(@q)
        if @search[:degraded]
          # Honest degradation: name it and show the browse — never fake results.
          @mode, @degraded, @page = :browse, @search[:degraded], @catalog.page(1)
        else
          @mode = :search
        end
      elsif params[:key].present? && params[:value].present?
        @mode    = :subject
        @subject = @catalog.subject(params[:key].to_s, params[:value].to_s,
                                    page: params[:page].to_i)
      else
        @mode = :browse
        @page = @catalog.page(params[:page].to_i)
      end
    end

    # The open-stacks gesture: land on a random record's full entry.
    def wander
      found = Enliterator::Catalog.new(context: current_context, type: safe_type).wander
      if found
        redirect_to status_record_path(found[0], found[1])
      else
        redirect_to catalog_path, alert: "Nothing is enliterated yet — there is nowhere to wander."
      end
    end

    private

    # The status#show pattern: a type param is only honored when it names a
    # registered tendable — anything else renders as an honest note, never a 500.
    def safe_type
      t = params[:type].presence
      return nil unless t
      klass = t.to_s.safe_constantize
      (klass && Enliterator.tendable_models.include?(klass)) ? klass.name : nil
    end
  end
end
