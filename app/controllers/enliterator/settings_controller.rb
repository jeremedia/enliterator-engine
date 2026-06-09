module Enliterator
  # The Settings surface — a read-only window onto the accumulating configuration of
  # THIS enliteration: the staffing org chart (facets → tiers, the escalation ladder,
  # the verify floor), the effective vocabulary per facet (code keys + the approved
  # keys that have accrued through curation), routing/capability, the considerer's
  # autonomy, and the tending behavior. Configuration lives in code (the host
  # initializer); this page reflects it, it does not edit it — the one thing that
  # genuinely accumulates at runtime, the approved vocabulary, is governed on Requests.
  class SettingsController < ApplicationController
    def index
      @config = Enliterator.configuration
      @policy = Enliterator.staffing

      @facets       = facet_names
      @contracts     = @facets.map { |s| facet_config(s) }
      @gateway_ready = @config.gateway_api_key.present? && @config.gateway_base_url.present?
      @conversation_tier_effective = @config.conversation_tier || @policy.ladder.last || "quality"
      @considerer_tier_effective   = @config.considerer_tier   || @policy.ladder.last || "quality"

      # What this enliteration actually works on. The in-memory registry only fills as
      # model classes autoload (lazy in dev), so the visit log is the truer authority —
      # prefer the types that have actually been tended, fall back to the registry.
      tended_types = Enliterator::Visit.distinct.pluck(:tendable_type).compact
      @models = tended_types.presence || Enliterator.tendable_models.map(&:name)

      # Live tally of what's accrued: approved terms now in force across all facets.
      @approved_live = @contracts.sum { |c| c[:terms].count { |t| t[:approved] } }
    end

    private

    def facet_names
      names = @policy.assignments.keys
      names = Array(@config.tending_facets).map(&:to_s) if names.empty?
      names
    end

    # The effective per-facet config: assigned tier, the climb from there, required
    # terms, and the effective vocabulary (code + approved), each term flagged code/approved.
    def facet_config(facet)
      tier = @policy.tier_for(facet)
      code = @policy.terms_for(facet) || {}
      eff  = Enliterator::Vocabulary.for(facet) || {}
      {
        facet:    facet,
        tier:     tier,
        climb:    @policy.ladder_from(tier),
        required: Array(@policy.required_terms(facet)),
        terms:    eff.map { |term, desc| { term: term, description: desc, approved: !code.key?(term) } }
      }
    end
  end
end
