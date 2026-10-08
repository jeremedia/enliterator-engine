# frozen_string_literal: true

module Enliterator
  # v0.89: refuse curation writes on a deployment that is not where curation
  # happens (`config.curation_writes = false`) — an import target whose
  # enliteration is replaced wholesale by the next import. Writing there would
  # be silently lost; refusing says so where the curator is looking.
  module CurationGuard
    extend ActiveSupport::Concern

    class_methods do
      def guard_curation_writes(*actions)
        before_action :refuse_curation_write!, only: actions
      end
    end

    private

    def refuse_curation_write!
      return if Enliterator.curation_writes?

      msg = Enliterator.curation_refusal
      respond_to do |format|
        format.html { redirect_back(fallback_location: root_path, alert: msg) }
        format.any  { render plain: msg, status: :forbidden }
      end
    end
  end
end
