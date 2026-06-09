module Enliterator
  # The Settings surface — a read-only window onto the accumulating configuration of
  # THIS enliteration: the staffing org chart (streams → tiers, the escalation ladder,
  # the verify floor), the effective vocabulary per stream (code keys + the approved
  # keys that have accrued through curation), routing/capability, the considerer's
  # autonomy, and the tending behavior. Configuration lives in code (the host
  # initializer); this page reflects it, it does not edit it — the one thing that
  # genuinely accumulates at runtime, the approved vocabulary, is governed on Requests.
  class SettingsController < ApplicationController
    def index
      @config = Enliterator.configuration
      @policy = Enliterator.staffing

      @streams       = stream_names
      @contracts     = @streams.map { |s| stream_config(s) }
      @gateway_ready = @config.gateway_api_key.present? && @config.gateway_base_url.present?
      @conversation_tier_effective = @config.conversation_tier || @policy.ladder.last || "quality"
      @considerer_tier_effective   = @config.considerer_tier   || @policy.ladder.last || "quality"

      # What this enliteration actually works on. The in-memory registry only fills as
      # model classes autoload (lazy in dev), so the visit log is the truer authority —
      # prefer the types that have actually been tended, fall back to the registry.
      tended_types = Enliterator::Visit.distinct.pluck(:tendable_type).compact
      @models = tended_types.presence || Enliterator.tendable_models.map(&:name)

      # Live tally of what's accrued: approved keys now in force across all streams.
      @approved_live = @contracts.sum { |c| c[:keys].count { |k| k[:approved] } }
    end

    private

    def stream_names
      names = @policy.assignments.keys
      names = Array(@config.tending_streams).map(&:to_s) if names.empty?
      names
    end

    # The effective per-stream config: assigned tier, the climb from there, required
    # keys, and the effective contract (code + approved), each key flagged code/approved.
    def stream_config(stream)
      tier = @policy.tier_for(stream)
      code = @policy.keys_for(stream) || {}
      eff  = Enliterator::Vocabulary.for(stream) || {}
      {
        stream:   stream,
        tier:     tier,
        climb:    @policy.ladder_from(tier),
        required: Array(@policy.required_keys(stream)),
        keys:     eff.map { |k, desc| { key: k, description: desc, approved: !code.key?(k) } }
      }
    end
  end
end
