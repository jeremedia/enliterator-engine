module Enliterator
  # v0.21: the Atlas — the enliterated collection drawn as a force-directed
  # graph. Read-only. The page EMBEDS its data (window.ATLAS_DATA) so the
  # same viewer renders live in the engine and standalone in the exported
  # file (rake enliterator:atlas); /atlas/data serves the JSON for tooling.
  # Scoped by the nav's context switcher like every surface.
  class AtlasController < ApplicationController
    def index
      @atlas = Enliterator::Atlas.build(context: current_context)
    end

    def data
      render json: Enliterator::Atlas.build(context: current_context)
    end
  end
end
