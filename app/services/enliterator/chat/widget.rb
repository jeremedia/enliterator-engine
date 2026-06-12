# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.28: the widget renderers — pure functions (tool_name, result) → self-
    # contained HTML, using the enl-widget component classes (the layout owns the
    # CSS). Tool data is UNTRUSTED: every interpolated value is HTML-escaped. An
    # unknown tool never raises — it renders a labeled JSON block (rule 3: visible,
    # not silent).
    module Widget
      module_function

      def render(tool_name, result)
        renderer = "render_#{tool_name}"
        respond_to?(renderer, true) ? send(renderer, result) : fallback_html(tool_name, result)
      end

      # --- helpers -----------------------------------------------------------
      # local alias for ERB::Util.html_escape — NOT Rails's view h(); this module
      # is never included into a view context
      def h(value) = ERB::Util.html_escape(value.to_s)

      # coerce any Hash to symbol keys; anything else → {}
      def symize(value) = value.is_a?(Hash) ? value.transform_keys(&:to_sym) : {}

      # named without a render_ prefix so render() can never dispatch to it — a
      # tool literally named "fallback" must not match this arity-2 method
      def fallback_html(tool_name, result)
        %(<div class="enl-widget enl-widget--raw"><div class="enl-widget__head">#{h(tool_name)}</div>) +
          %(<pre class="enl-widget__json">#{h(JSON.pretty_generate(result))}</pre></div>)
      end

      # --- record_entry ------------------------------------------------------
      def render_record_entry(result)
        r = symize(result)
        # r[:entry] intentionally omitted — the loop renders the widget inline; the URL isn't surfaced here
        facets = (r[:claims_by_facet] || {}).map do |facet, claims|
          rows = Array(claims).map { |c| claim_row(c) }.join
          %(<div class="enl-widget__facet"><div class="enl-widget__facet-name">#{h(facet)}</div>#{rows}</div>)
        end.join
        %(<div class="enl-widget enl-widget--record">) +
          %(<div class="enl-widget__head">#{h(r[:label])}</div>#{facets}</div>)
      end

      def claim_row(claim)
        c = symize(claim)
        verdict = c[:audit_verdict] ? %( <span class="enl-claim__verdict">#{h(c[:audit_verdict])}</span>) : ""
        conf = c[:confidence] ? %( <span class="enl-claim__conf">#{h(c[:confidence])}</span>) : ""
        %(<div class="enl-claim"><span class="enl-claim__key">#{h(c[:key])}</span>: ) +
          %(<span class="enl-claim__value">#{h(c[:value])}</span>#{conf}#{verdict}</div>)
      end

      # --- provenance --------------------------------------------------------
      def render_provenance(result)
        r = symize(result)
        claim = symize(r[:claim])
        visit = symize(r[:visit])
        audits = Array(r[:audits]).map do |a|
          a = symize(a)
          %(<li class="enl-prov__audit"><b>#{h(a[:source])}</b>: #{h(a[:verdict])} — #{h(a[:rationale])}</li>)
        end.join
        %(<div class="enl-widget enl-widget--prov">) +
          %(<div class="enl-prov__claim">#{h(claim[:key])}: #{h(claim[:value])}</div>) +
          %(<div class="enl-prov__visit">#{h(visit[:tier])} · #{h(visit[:model])} · #{h(visit[:at])}</div>) +
          %(<ul class="enl-prov__audits">#{audits}</ul></div>)
      end

      # --- accuracy ----------------------------------------------------------
      def render_accuracy(result)
        r = symize(result)
        rows = Array(r[:by_facet_and_tier]).map do |row|
          row = symize(row)
          %(<tr><td>#{h(row[:facet])}</td><td>#{h(row[:tier])}</td>) +
            %(<td>#{h(row[:audited])}</td><td>#{h(row[:supported])}</td></tr>)
        end.join
        anchor = symize(r[:anchor_agreement])[:rate]
        %(<div class="enl-widget enl-widget--accuracy">) +
          %(<table class="enl-accuracy"><thead><tr><th>facet</th><th>tier</th><th>audited</th><th>supported</th></tr></thead>) +
          %(<tbody>#{rows}</tbody></table>) +
          (anchor ? %(<div class="enl-accuracy__anchor">anchor agreement: #{h(anchor)}</div>) : "") + %(</div>)
      end

      # --- trajectory --------------------------------------------------------
      def render_trajectory(result)
        r = symize(result)
        steps = Array(r[:steps]).map do |s|
          s = symize(s)
          ops = (s[:ops] || {}).map { |k, v| "#{h(k)} #{h(v)}" }.join(", ")
          %(<li class="enl-step"><span class="enl-step__at">#{h(s[:at])}</span> ) +
            %(<span class="enl-step__tier">#{h(s[:tier])}</span> <span class="enl-step__ops">#{ops}</span></li>)
        end.join
        %(<div class="enl-widget enl-widget--traj"><div class="enl-widget__head">#{h(r[:facet])}</div>) +
          %(<ol class="enl-traj">#{steps}</ol></div>)
      end
    end
  end
end
