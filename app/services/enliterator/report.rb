module Enliterator
  # The tending rollup — the "smoke alarm" the Visit table always COULD answer but
  # nothing surfaced. A pure-read aggregation over the immutable Visit history that
  # makes a misconfiguration glaring at a glance: the adapter/model mix exposes a
  # `null` model instantly, the empty-final rate exposes a facet that "succeeded"
  # while writing nothing, and required_unmet counts facets that missed a mandated
  # fact. No network, no gateway call — one ActiveRecord read.
  #
  #   Enliterator::Report.summary
  #   Enliterator::Report.summary(since: 7.days, facet: "authorship")
  #   # => {
  #   #   "authorship" => {
  #   #     total: 250, status: {"succeeded"=>250},
  #   #     adapter_mix: {"cheap"=>249, "null"=>1},   # <- the smoke alarm
  #   #     tier_mix: {"cheap"=>249, "quality"=>1},
  #   #     escalated: 1, escalation_rate: 0.004,
  #   #     final_total: 250, empty_final: 31, empty_final_rate: 0.124,
  #   #     required_unmet: 6,
  #   #     confidence: {"0.8-1.0"=>219, "nil"=>31},
  #   #     spend: { tokens: {...}, by_tier: {...} }
  #   #   }, ...
  #   # }
  module Report
    module_function

    # Roll up the Visit history per facet. See the module doc for the shape.
    #
    # @param host   [String, nil] forwarded to Spend (engine tables are per-host).
    # @param since  [Time, ActiveSupport::Duration, nil] only visits at/after this
    #   point. A Duration (e.g. 7.days) reads as "ago".
    # @param facet [String, Symbol, nil] restrict to one facet.
    # @return [Hash{String => Hash}]
    def summary(host: nil, since: nil, facet: nil)
      rows = visit_scope(since: since, facet: facet)
               .pluck(:facet, :status, :model, :tier, :escalation_step, :applied, :confidence, :reconciliation)

      data = Hash.new { |h, s| h[s] = new_bucket }

      rows.each do |s, status, model, tier, esc, applied, conf, recon|
        b = data[s.to_s]
        b[:total] += 1
        b[:status][status.to_s] += 1
        b[:adapter_mix][model.to_s.presence || "unknown"] += 1
        b[:tier_mix][tier.to_s.presence || "unknown"] += 1
        b[:escalated] += 1 if esc.to_i.positive?
        b[:confidence][conf_label(conf)] += 1

        if status.to_s == "succeeded" && applied
          b[:final_total]     += 1
          b[:empty_final]     += 1 if empty_recon?(recon)
          b[:required_unmet]  += 1 if recon_flag?(recon, "required_unmet")
        end
      end

      spend = Enliterator::Spend.by_facet(host: host, since: since, facet: facet)

      data.each do |s, b|
        b[:escalation_rate]  = ratio(b[:escalated],   b[:total])
        b[:empty_final_rate] = ratio(b[:empty_final], b[:final_total])
        b[:spend]            = spend[s] || { tokens: zero_tokens, by_tier: {} }
        # Freeze the count hashes into plain hashes (drop the default-0 proc).
        %i[status adapter_mix tier_mix confidence].each { |k| b[k] = b[k].to_h }
      end

      data
    end

    # ---- internals -------------------------------------------------------

    def visit_scope(since:, facet:)
      scope = Enliterator::Visit.all
      scope = scope.where(facet: facet.to_s) if facet
      if since
        cutoff = since.is_a?(ActiveSupport::Duration) ? since.ago : since
        scope  = scope.where("enliterator_visits.created_at >= ?", cutoff)
      end
      scope
    end

    def new_bucket
      {
        total: 0,
        status:       Hash.new(0),
        adapter_mix:  Hash.new(0),
        tier_mix:     Hash.new(0),
        escalated: 0,
        final_total: 0,
        empty_final: 0,
        required_unmet: 0,
        confidence:   Hash.new(0)
      }
    end

    # A succeeded+applied visit that wrote nothing (no add/update/delete) — the
    # signature of the silent no-op (and of a genuinely-empty extraction).
    def empty_recon?(recon)
      return true unless recon.is_a?(Hash)
      %w[added updated deleted].sum { |k| Array(recon[k] || recon[k.to_sym]).size }.zero?
    end

    def recon_flag?(recon, key)
      return false unless recon.is_a?(Hash)
      truthy?(recon[key] || recon[key.to_sym])
    end

    def conf_label(conf)
      return "nil" if conf.nil?
      c = conf.to_f
      if    c < 0.2 then "0.0-0.2"
      elsif c < 0.4 then "0.2-0.4"
      elsif c < 0.6 then "0.4-0.6"
      elsif c < 0.8 then "0.6-0.8"
      else               "0.8-1.0"
      end
    end

    def ratio(num, den)
      den.to_i.zero? ? 0.0 : (num.to_f / den).round(3)
    end

    def zero_tokens
      { "input" => 0, "output" => 0, "total" => 0 }
    end

    def truthy?(value)
      value == true || value == "true" || value == 1 || value == "1"
    end
  end
end
