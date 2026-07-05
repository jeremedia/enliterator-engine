module Enliterator
  # v0.48: the deployment profile — the engine declaring its own live shape.
  #
  # This session's bug started because the launchd LOG isn't self-describing:
  # it carries stale aborts with no way to know they're stale, so the truth
  # lives out-of-band in the ledger. The fix for an enliteration's *shape* is
  # to not repeat that mistake — have the running system declare itself, so a
  # skill (or an operator) reads the engine instead of carrying out-of-band
  # knowledge about it.
  #
  # `Deployment.profile` is a pure read over config + the staffing policy + the
  # tendable registry + the ledger. It is deliberately explicit about what it
  # CANNOT introspect — the schedule/cadence (the host scheduler owns the
  # timing), log paths, scheduler labels, and the human ops caveats — because
  # those genuinely live outside the app, in the host's deployment doc
  # (`doc/enliterator/deployment.md`). Naming the gap is the point: the profile
  # tells you where the rest of the truth lives.
  #
  #   Enliterator::Deployment.profile   # => a structured Hash
  #
  # Surfaced as `rake enliterator:deployment` and consumed by the Settings
  # surface. Pure read — no network, no gateway, no cache.
  module Deployment
    module_function

    CADENCE_SAMPLE = 8 # how many recent beats to infer cadence from

    # @return [Hash] see the section builders below for the shape.
    def profile
      {
        generated_at: Time.current,
        mode:         mode,
        config:       config,
        staffing:     staffing,
        tendables:    tendables,
        contexts:     contexts,
        heartbeat:    heartbeat,
        external:     external
      }
    end

    # ---- sections ------------------------------------------------------------

    # What's running and whether it can reach a real model.
    def mode
      c = Enliterator.configuration
      {
        rails_env:      Rails.env.to_s,
        gateway_ready:  Enliterator.gateway_configured?, # the one shared predicate
        llm:            Enliterator.gateway_configured? ? "gateway" : (c.llm_adapter&.class&.name || "null"),
        embedder:       c.embedder_adapter&.class&.name || "null",
        allow_null_llm: !!c.allow_null_llm,
        error_detail:   !!c.error_detail?
      }
    end

    # The accumulating configuration of THIS enliteration. Mirrors the six keys
    # the heartbeat snapshots per cycle (so they read consistently with the
    # ledger) and widens to the full operational set the snapshot omits.
    def config
      c = Enliterator.configuration
      {
        # the heartbeat config_snapshot subset (kept value-consistent with it)
        heartbeat_budget_tokens:      c.heartbeat_budget_tokens,
        heartbeat_change_share:       c.heartbeat_change_share,
        heartbeat_neighbor_threshold: c.heartbeat_neighbor_threshold,
        stale_after_seconds:          c.stale_after.to_i,
        tending_facets:               Array(c.tending_facets).map(&:to_s),
        apply_approved_keys:          c.apply_approved_keys,
        # widened: the rest of the knobs an operator/skill wants to see
        heartbeat_audit_sample:       c.heartbeat_audit_sample,
        audit_tier:                   c.audit_tier,
        considerer_autonomy:          c.considerer_autonomy,
        considerer_min_confidence:    c.considerer_min_confidence,
        escalation_threshold:         c.escalation_threshold,
        record_lacunae:               c.record_lacunae,
        name_authority_keys:          Array(c.name_authority_keys).map(&:to_s),
        read_time_warrant:            c.read_time_warrant,
        # the shape-of-a-collection flags (v0.55–v0.57)
        synthesized_tendables:        Enliterator.synthesized_tendable_names,
        collection_tendable:          c.collection_tendable&.to_s,
        topology_wholes:              Array(c.topology&.wholes).map { |w| "#{w.whole_type}<#{w.member_type}" },
        default_reading_scope:        c.default_reading_scope&.to_s,
        gateway_timeout:              c.gateway_timeout,
        gateway_max_retries:          c.gateway_max_retries,
        atlas_node_cap:               c.atlas_node_cap,
        chat: {
          federation:      c.chat_federation,
          followups:       c.chat_followups,
          register:        c.chat_register,
          persona_editing: c.chat_persona_editing,
          retention:       c.chat_retention,
          sources:         c.chat_sources
        }
      }
    end

    # The org chart: the escalation ladder, every tier the policy names, the
    # verify floor, and each facet's tier + whether the pacemaker schedules it.
    # Enliterator.staffing always returns a Policy (the safe default when the
    # host configures none), so there is no nil to guard.
    def staffing
      policy = Enliterator.staffing
      {
        ladder:               policy.ladder,
        tiers:                policy.referenced_tiers,
        embedding_tier:       policy.embedding_tier,
        verify_floor:         policy.verify_floor,
        escalation_threshold: policy.escalation_threshold,
        max_promotions:       policy.max_promotions,
        on_prem_tiers:        policy.on_prem_tiers,
        facets:               declared_facets(policy)
      }
    end

    # The FULL facet set: root-declared plus every context block. Showing only
    # root would under-represent what the engine tends (a deployment often
    # declares most facets per-context). Each row is tagged with the context
    # that declared it (origin) and the tier resolved along that scope.
    def declared_facets(policy)
      rows = policy.facets_declared_in(nil).map do |facet|
        facet_row(policy, facet, origin: "root", path: nil, scope: nil)
      end
      policy.declared_context_keys.each do |key|
        policy.facets_declared_in(key).each do |facet|
          rows << facet_row(policy, facet, origin: key, path: [ key ], scope: key)
        end
      end
      rows
    end

    def facet_row(policy, facet, origin:, path:, scope:)
      { facet: facet, tier: policy.tier_for(facet, path: path),
        scheduled: policy.scheduled?(facet, scope), origin: origin }
    end

    # What this enliteration actually works on. The in-memory registry only
    # fills as model classes autoload (lazy in dev), so the visit log is the
    # truer authority — host types that have actually been tended, falling back
    # to the registry. (The established Settings/Planner idiom.)
    def tendables
      Enliterator.mask_synthesized(
        Enliterator::Visit.host_tendable_types.presence ||
          Enliterator.tendable_models.map(&:name)
      )
    end

    # The collection context tree. NULL context_id IS the root scope; a root
    # Context row is just the tree anchor. `derived` distinguishes machine-owned
    # topology views (v0.56) from hand-curated lenses.
    def contexts
      {
        count: Enliterator::Context.count,
        derived: Enliterator::Context.where.not(derived_from_type: nil).count,
        roots: Enliterator::Context.roots.pluck(:key).compact
      }
    end

    # The last cycle from the ledger + an INFERRED cadence (the schedule itself
    # is external — see #external). Cadence is the mean gap between recent beat
    # starts; never authoritative, labelled as inferred.
    def heartbeat
      beats = Enliterator::Heartbeat.order(:started_at)
      last  = beats.last
      starts = beats.where.not(started_at: nil).last(CADENCE_SAMPLE).map(&:started_at)
      cadence =
        if starts.size >= 2
          deltas = starts.each_cons(2).map { |a, b| b - a }
          (deltas.sum / deltas.size / 3600.0).round(2)
        end
      {
        last: last && {
          id:          last.id,
          started_at:  last.started_at,
          finished_at: last.finished_at,
          error:       last.error.present?,
          tokens:      last.tokens_spent.is_a?(Hash) ? last.tokens_spent["total"].to_i : 0
        },
        inferred_cadence_hours: cadence,
        schedule: "external (host scheduler)"
      }
    end

    # The self-describing-affordance payoff: name what the app CANNOT know about
    # itself, and point at where that truth lives. A skill reads this and knows
    # to consult the host doc rather than guess.
    def external
      {
        not_introspectable: [
          "heartbeat schedule / cadence authority — the host scheduler owns the timing; the cadence above is inferred from past beats, not declared",
          "log file paths — the host's Rails logger and/or scheduler stdout/stderr redirect",
          "scheduler job labels — launchd / systemd / cron live outside the app",
          "operator, credential-refresh cadence, and provider/credit caveats"
        ],
        host_doc: "doc/enliterator/deployment.md"
      }
    end
  end
end
