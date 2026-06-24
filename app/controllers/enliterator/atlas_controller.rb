module Enliterator
  # v0.21: the Atlas — the enliterated collection drawn as a force-directed
  # graph. Read-only. Live mode fetches /atlas/data asynchronously so the
  # page shell returns immediately; the exported file (rake enliterator:atlas)
  # embeds the same data for standalone use.
  # Scoped by the nav's context switcher like every surface.
  class AtlasController < ApplicationController
    def index
      data_params = { mode: "overview" }
      data_params[:context] = current_context.key if current_context
      @atlas_data_url = atlas_data_path(data_params)
    end

    def data
      render json: Enliterator::Atlas.build(
        context: current_context,
        mode: params[:mode].presence,
        focus: params[:focus].presence,
        depth: params[:depth].presence,
        min_confidence: params[:min_confidence].presence,
        audit: params[:audit].presence,
        categories: params[:categories].presence,
        since: params[:since].presence,
        until: params[:until].presence
      )
    end

    # The Ego-lens inspector (Stage 1): one node's live claims with provenance
    # plus its open lacunae. Read-only JSON; scoped by the nav context like data.
    def node
      render json: Enliterator::Atlas.inspect(
        type: params[:type].to_s, id: params[:id].to_s, context: current_context
      )
    end
  end
end
