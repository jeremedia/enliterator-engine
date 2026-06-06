module Enliterator
  # The engine's OWN per-loop spend ledger, read locally from Visit rows.
  #
  # Every gateway request the Visitor makes carries LiteLLM `metadata: {tags: [...]}`
  # so LiteLLM logs authoritative dollars to `LiteLLM_SpendLogs.request_tags` /
  # `DailyTagSpend`. But project keys can't read those tables back (master/admin
  # only). This module is the engine's independent token ledger: it groups
  # `Visit.tokens` by stream (and tier) over the immutable visit history. No
  # gateway call, no network — a pure ActiveRecord read.
  #
  # Tags are the join key to LiteLLM's authoritative dollars; this ledger is the
  # local, always-available approximation (tokens, and optionally $ via a price map).
  #
  #   Enliterator::Spend.by_stream
  #   # => {
  #   #   "summary" => {
  #   #     tokens:  { "input" => 1200, "output" => 300, "total" => 1500 },
  #   #     by_tier: {
  #   #       "cheap"   => { "input" => 1000, "output" => 200, "total" => 1200 },
  #   #       "quality" => { "input" =>  200, "output" => 100, "total" =>  300 }
  #   #     }
  #   #   }
  #   # }
  #
  # With a price map (USD per 1K tokens, per tier), an estimated cost is added:
  #
  #   Enliterator::Spend.by_stream(price_map: {
  #     "cheap"   => { input: 0.0,    output: 0.0 },
  #     "quality" => { input: 0.00125, output: 0.01 }
  #   })
  #   # => { "summary" => { tokens: {...}, by_tier: {...}, cost_usd: 0.0035 }, ... }
  module Spend
    module_function

    # Group visit token usage by stream (and tier) from the Visit ledger.
    #
    # @param host     [String, nil] reserved for future host-scoped ledgers; the
    #   engine's tables are already per-host (one engine per app), so this is a
    #   no-op filter today. Accepted so callers can pass it forward harmlessly.
    # @param since    [Time, ActiveSupport::Duration, nil] only count visits created
    #   at/after this point. A Duration (e.g. 7.days) is read as "ago".
    # @param stream   [String, Symbol, nil] restrict to a single stream.
    # @param price_map [Hash, nil] optional per-tier USD-per-1K-token rates,
    #   `{tier => {input:, output:}}`; when given, a `:cost_usd` estimate is added
    #   to each stream. Default nil → tokens only (no dollar guesses).
    #
    # @return [Hash{String => Hash}] `{stream => {tokens:, by_tier:, [cost_usd:]}}`.
    def by_stream(host: nil, since: nil, stream: nil, price_map: nil)
      scope = visit_scope(since: since, stream: stream)

      result = Hash.new { |h, s| h[s] = { tokens: zero_tokens, by_tier: {} } }

      scope.find_each do |visit|
        bucket = result[visit.stream.to_s]
        tier   = visit.tier.to_s.presence || "unknown"
        tokens = token_counts(visit.tokens)

        tier_bucket = (bucket[:by_tier][tier] ||= zero_tokens)
        accumulate!(bucket[:tokens], tokens)
        accumulate!(tier_bucket, tokens)
      end

      if price_map
        result.each_value { |bucket| bucket[:cost_usd] = estimate_cost(bucket[:by_tier], price_map) }
      end

      result
    end

    # ---- internals -------------------------------------------------------

    def visit_scope(since:, stream:)
      scope = Enliterator::Visit.all
      scope = scope.where(stream: stream.to_s) if stream
      if since
        cutoff = since.is_a?(ActiveSupport::Duration) ? since.ago : since
        scope  = scope.where("enliterator_visits.created_at >= ?", cutoff)
      end
      scope
    end

    def zero_tokens
      { "input" => 0, "output" => 0, "total" => 0 }
    end

    # Read the three canonical counters out of a Visit.tokens jsonb, tolerating
    # string OR symbol keys (jsonb round-trips to string keys; in-memory stubs may
    # use symbols). Missing counters read as 0.
    def token_counts(tokens)
      h = tokens.is_a?(Hash) ? tokens : {}
      {
        "input"  => fetch_count(h, :input),
        "output" => fetch_count(h, :output),
        "total"  => fetch_count(h, :total)
      }
    end

    def fetch_count(hash, key)
      (hash[key.to_s] || hash[key] || 0).to_i
    end

    def accumulate!(into, counts)
      into["input"]  += counts["input"]
      into["output"] += counts["output"]
      into["total"]  += counts["total"]
      into
    end

    # Estimate USD from per-tier token sums and a price map of USD-per-1K-tokens.
    # A tier absent from the price map contributes 0 (free / unpriced).
    def estimate_cost(by_tier, price_map)
      total = 0.0
      by_tier.each do |tier, counts|
        rates = price_map[tier] || price_map[tier.to_sym]
        next unless rates

        in_rate  = (rates[:input]  || rates["input"]  || 0).to_f
        out_rate = (rates[:output] || rates["output"] || 0).to_f
        total += (counts["input"]  / 1000.0) * in_rate
        total += (counts["output"] / 1000.0) * out_rate
      end
      total.round(6)
    end
  end
end
