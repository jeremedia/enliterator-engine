module Enliterator
  # The collection SELF-PORTRAIT — what an enliteration knows about itself.
  #
  # A pure-read aggregation (no network) that answers "what is in here and what has
  # it learned": per-facet tended-record counts, the claim-key VOCABULARY with live
  # counts + sample values, the CONNECTION graph (cross-record claims), tending
  # health (Report), and the open vocabulary GAPS (Suggestion). It powers both the
  # status browser overview and the conversation UI's top-level grounding — the
  # chapter's "the collection looked back," rendered as data the collection can speak.
  #
  #   Enliterator::Synopsis.build                       # full self-portrait (root)
  #   Enliterator::Synopsis.build(context: ctx)         # one context's portrait
  #   Enliterator::Synopsis.to_prompt(Synopsis.build)   # compact text for an LLM
  #
  # v0.13: context-aware. Within a context the portrait shows the context's
  # EFFECTIVE facets (inherited + own), claim/visit counts scoped up its path
  # (root rule: [nil, *path_ids]), and its own vocabulary gaps. With no context:
  # the root view — the unfiltered union, byte-identical to v0.12.
  #
  # NOTE on the claim→facet mapping: Claim carries no `facet` column (the facet
  # lives on the Visit). So tended_count is derived from Visit rows, and the
  # vocabulary per facet comes from the staffing CONTRACT (terms_for), not the claims.
  module Synopsis
    module_function

    # A facet whose NAME signals it holds cross-record connections.
    CONNECTION_FACET_RX = /connection|relation|link/i
    # A claim KEY that names a cross-record link (fallback when no connection facet).
    CONNECTION_KEY_RX    = /\A(related_|connected_|cites|references)|(_cluster|_network|thematic)/i

    # v0.20: the portrait is PREPARED — served from the host's Rails.cache
    # (Solid Cache, Redis, memory; a null store recomputes, byte-identical
    # behavior). The key carries the latest heartbeat id so each cycle
    # republishes the portrait; the short TTL covers manual tends between
    # cycles. `generated_at` inside the cached value is the honest prepared-at
    # stamp. Status AND the chat grounding both read through this.
    ROLLUP_TTL = 5.minutes

    def build(host: nil, since: nil, context: nil, sample_cap: 3, value_chars: 80)
      key = [ "enliterator/synopsis", context&.key || "root", host.respond_to?(:name) ? host.name : host,
              since, sample_cap, value_chars, "hb#{Enliterator::Heartbeat.maximum(:id) || 0}" ].join("/")
      Rails.cache.fetch(key, expires_in: ROLLUP_TTL) do
        assemble(host: host, since: since, context: context, sample_cap: sample_cap, value_chars: value_chars)
      end
    end

    # Build the self-portrait (uncached). `sample_cap` / `value_chars` bound the
    # prompt size so to_prompt stays small regardless of corpus size.
    def assemble(host: nil, since: nil, context: nil, sample_cap: 3, value_chars: 80)
      policy = Enliterator.staffing
      names  = facet_names(policy, context)

      {
        generated_at: Time.current,
        context:      context&.key,
        facets: names.map { |s| facet_portrait(policy, s, context: context, sample_cap: sample_cap, value_chars: value_chars) },
        connections: connection_portrait(policy, names, context: context, sample_cap: sample_cap, value_chars: value_chars),
        health: Enliterator::Report.summary(host: host, since: since),
        # Root = the unfiltered union (rule 1); a context = its own proposals.
        gaps:   (context ? Enliterator::Suggestion.gaps(context: context) : Enliterator::Suggestion.gaps).first(5),
        models: Enliterator.tendable_models.map(&:name)
      }
    end

    # Render a synopsis as compact, LLM-injectable plaintext (one line per item, NOT
    # a JSON dump). Samples are already truncated by build, so this is bounded.
    def to_prompt(synopsis)
      lines = [ "COLLECTION SELF-PORTRAIT" ]
      lines << "Viewed through context: #{synopsis[:context]}" if synopsis[:context]
      models = Array(synopsis[:models])
      lines << "Tended models: #{models.join(', ')}" if models.any?

      Array(synopsis[:facets]).each do |st|
        lines << "Facet \"#{st[:facet]}\" (tier #{st[:tier]}): #{st[:tended_count]} records tended."
        Array(st[:vocabulary]).each do |v|
          eg = v[:samples].to_a.first
          lines << "  - #{v[:key]}: #{v[:live_claims]} live claim(s)#{eg ? " — e.g. #{eg}" : ''}"
        end
      end

      conns = Array(synopsis[:connections])
      if conns.any?
        lines << "Cross-record connections:"
        conns.each do |c|
          eg = c[:samples].to_a.first
          lines << "  - #{c[:key]}: #{c[:live_claims]} live claim(s)#{eg ? " — e.g. #{eg}" : ''}"
        end
      end

      gaps = Array(synopsis[:gaps])
      lines << "Open vocabulary gaps: #{gaps.map { |g| "#{g[:proposed_key]}(#{g[:count]})" }.join(', ')}" if gaps.any?

      lines.join("\n")
    end

    # ---- internals -------------------------------------------------------

    # The facets in view: a context's EFFECTIVE set (inherited + own, from the
    # policy path merge); at root, the root declarations (v0.12 behavior).
    def facet_names(policy, context = nil)
      names = policy.facets_for(context&.path_keys).keys
      names = Array(Enliterator.configuration.tending_facets).map(&:to_s) if names.empty?
      names
    end

    def facet_portrait(policy, facet, context: nil, sample_cap:, value_chars:)
      path      = context&.path_keys
      contract  = Enliterator::Vocabulary.for(facet, context: context) || {} # effective: code + approved
      code_keys = (policy.terms_for(facet, path: path) || {}).keys.to_set
      {
        facet:       facet,
        tier:         policy.tier_for(facet, path: path),
        tended_count: tended_count(facet, context),
        vocabulary:   contract.map do |key, desc|
          # `approved: true` ⇒ a curator-adopted key that's live but not yet codified.
          key_summary(key, context: context, description: desc, sample_cap: sample_cap, value_chars: value_chars)
            .merge(approved: !code_keys.include?(key))
        end
      }
    end

    # Distinct records that have an applied+succeeded visit on this facet — the only
    # reliable facet→record mapping (Claim has no facet column). Scoped up the
    # context's path; unfiltered at root (the union view).
    def tended_count(facet, context = nil)
      scope = Enliterator::Visit.where(facet: facet, status: "succeeded", applied: true)
      scope = scope.where(context_id: context.scope_ids) if context
      scope.distinct.pluck(:tendable_type, :tendable_id).size
    end

    def key_summary(key, context: nil, description: nil, sample_cap:, value_chars:)
      live = Enliterator::Claim.live.where(key: key)
      live = live.where(context_id: context.scope_ids) if context
      summary = {
        key:         key,
        live_claims: live.count,
        samples:     live.limit(sample_cap).pluck(:value).map { |v| truncate_value(v, value_chars) }
      }
      summary[:description] = description if description
      summary
    end

    # Connection keys: prefer those owned by a facet NAMED like a connection facet;
    # else any contract key that LOOKS like a cross-record link. Empty ⇒ no panel.
    def connection_portrait(policy, names, context: nil, sample_cap:, value_chars:)
      keys = names.select { |s| s.match?(CONNECTION_FACET_RX) }
                  .flat_map { |s| (Enliterator::Vocabulary.for(s, context: context) || {}).keys }
      if keys.empty?
        keys = names.flat_map { |s| (Enliterator::Vocabulary.for(s, context: context) || {}).keys }
                    .select { |k| k.to_s.match?(CONNECTION_KEY_RX) }
      end
      keys.uniq.map { |k| key_summary(k, context: context, sample_cap: sample_cap, value_chars: value_chars) }
    end

    def truncate_value(value, chars)
      s = value.is_a?(String) ? value : value.to_json
      s.length > chars ? "#{s[0, chars]}…" : s
    end
  end
end
