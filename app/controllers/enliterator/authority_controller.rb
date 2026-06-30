module Enliterator
  # The authority file (v0.51), mounted at /enliterator/vocabulary. One read-only action;
  # all the work lives in Enliterator::Authority. Adoption-gated PER CONTEXT — a context
  # that has never had a proposal renders the zero-state card, not an empty frame (and a
  # flat install with no proposals at all stays byte-identical: an empty page body).
  class AuthorityController < ApplicationController
    def index
      @adopted = Enliterator::Suggestion.where(context_id: current_context&.id).exists?
      return unless @adopted

      @overview = Enliterator::Authority.new(context: current_context).overview
    end
  end
end
