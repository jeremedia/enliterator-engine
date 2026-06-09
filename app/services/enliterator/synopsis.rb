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
  #   Enliterator::Synopsis.build                       # full self-portrait
  #   Enliterator::Synopsis.to_prompt(Synopsis.build)   # compact text for an LLM
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

    # Build the self-portrait. `sample_cap` / `value_chars` bound the prompt size so
    # to_prompt stays small regardless of corpus size.
    def build(host: nil, since: nil, sample_cap: 3, value_chars: 80)
      policy = Enliterator.staffing
      names  = facet_names(policy)

      {
        generated_at: Time.current,
        facets: names.map { |s| facet_portrait(policy, s, sample_cap: sample_cap, value_chars: value_chars) },
        connections: connection_portrait(policy, names, sample_cap: sample_cap, value_chars: value_chars),
        health: Enliterator::Report.summary(host: host, since: since),
        gaps:   Enliterator::Suggestion.gaps.first(5),
        models: Enliterator.tendable_models.map(&:name)
      }
    end

    # Render a synopsis as compact, LLM-injectable plaintext (one line per item, NOT
    # a JSON dump). Samples are already truncated by build, so this is bounded.
    def to_prompt(synopsis)
      lines = [ "COLLECTION SELF-PORTRAIT" ]
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

    def facet_names(policy)
      names = policy.assignments.keys
      names = Array(Enliterator.configuration.tending_facets).map(&:to_s) if names.empty?
      names
    end

    def facet_portrait(policy, facet, sample_cap:, value_chars:)
      contract  = Enliterator::Vocabulary.for(facet) || {} # effective: code + approved keys
      code_keys = (policy.terms_for(facet) || {}).keys.to_set
      {
        facet:       facet,
        tier:         policy.tier_for(facet),
        tended_count: tended_count(facet),
        vocabulary:   contract.map do |key, desc|
          # `approved: true` ⇒ a curator-adopted key that's live but not yet codified.
          key_summary(key, description: desc, sample_cap: sample_cap, value_chars: value_chars)
            .merge(approved: !code_keys.include?(key))
        end
      }
    end

    # Distinct records that have an applied+succeeded visit on this facet — the only
    # reliable facet→record mapping (Claim has no facet column).
    def tended_count(facet)
      Enliterator::Visit
        .where(facet: facet, status: "succeeded", applied: true)
        .distinct.pluck(:tendable_type, :tendable_id).size
    end

    def key_summary(key, description: nil, sample_cap:, value_chars:)
      live = Enliterator::Claim.live.where(key: key)
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
    def connection_portrait(policy, names, sample_cap:, value_chars:)
      keys = names.select { |s| s.match?(CONNECTION_FACET_RX) }
                  .flat_map { |s| (Enliterator::Vocabulary.for(s) || {}).keys }
      if keys.empty?
        keys = names.flat_map { |s| (Enliterator::Vocabulary.for(s) || {}).keys }.select { |k| k.to_s.match?(CONNECTION_KEY_RX) }
      end
      keys.uniq.map { |k| key_summary(k, sample_cap: sample_cap, value_chars: value_chars) }
    end

    def truncate_value(value, chars)
      s = value.is_a?(String) ? value : value.to_json
      s.length > chars ? "#{s[0, chars]}…" : s
    end
  end
end
