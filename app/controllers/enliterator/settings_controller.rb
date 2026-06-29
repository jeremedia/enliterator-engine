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

      # v0.13: the selected context's EFFECTIVE facet set (inherited + own);
      # root = the root declarations (v0.12 view).
      @facet_origins = Enliterator.staffing.facets_for(current_context&.path_keys)
      @facets       = facet_names
      @contracts     = @facets.map { |s| facet_config(s) }
      # v0.48: gateway-ready and the tended-types idiom now have ONE definition,
      # shared with Deployment.profile so the page and the rake can't drift.
      @gateway_ready = Enliterator.gateway_configured?
      @conversation_tier_effective = @config.conversation_tier || @policy.ladder.last || "quality"
      @considerer_tier_effective   = @config.considerer_tier   || @policy.ladder.last || "quality"

      # What this enliteration actually works on (host types only — v0.25: tended
      # Parts are internal). Visit log first, registry fallback.
      @models = Enliterator::Deployment.tendables

      # Live tally of what's accrued: approved terms now in force across all facets.
      @approved_live = @contracts.sum { |c| c[:terms].count { |t| t[:approved] } }

      # v0.15: the heartbeat's knobs + the last cycle from the ledger (cheap
      # reads — no planner queries on this page).
      @last_heartbeat = Enliterator::Heartbeat.order(:started_at).last
    end

    private

    def facet_names
      names = @facet_origins.keys
      names = Array(@config.tending_facets).map(&:to_s) if names.empty?
      names
    end

    # The effective per-facet config along the current context's path: assigned
    # tier, the climb from there, required terms, and the effective vocabulary
    # (code + approved), each term flagged code/approved.
    def facet_config(facet)
      path = current_context&.path_keys
      tier = @policy.tier_for(facet, path: path)
      code = @policy.terms_for(facet, path: path) || {}
      eff  = Enliterator::Vocabulary.for(facet, context: current_context) || {}
      {
        facet:    facet,
        origin:   @facet_origins[facet],   # which context declared it ("root" or a key)
        tier:     tier,
        climb:    @policy.ladder_from(tier),
        required: Array(@policy.required_terms(facet, path: path)),
        terms:    eff.map { |term, desc| { term: term, description: desc, approved: !code.key?(term) } }
      }
    end
  end
end
