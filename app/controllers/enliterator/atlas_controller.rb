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
        focus: params[:focus].presence
      )
    end
  end
end
