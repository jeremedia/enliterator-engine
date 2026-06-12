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

      # named without a render_ prefix so render() can never dispatch to it — a
      # tool literally named "fallback" must not match this arity-2 method
      def fallback_html(tool_name, result)
        %(<div class="enl-widget enl-widget--raw"><div class="enl-widget__head">#{h(tool_name)}</div>) +
          %(<pre class="enl-widget__json">#{h(JSON.pretty_generate(result))}</pre></div>)
      end

      # --- record_entry ------------------------------------------------------
      def render_record_entry(result)
        r = result.is_a?(Hash) ? result.transform_keys(&:to_sym) : {}
        # r[:entry] intentionally omitted — the loop renders the widget inline; the URL isn't surfaced here
        facets = (r[:claims_by_facet] || {}).map do |facet, claims|
          rows = Array(claims).map { |c| claim_row(c) }.join
          %(<div class="enl-widget__facet"><div class="enl-widget__facet-name">#{h(facet)}</div>#{rows}</div>)
        end.join
        %(<div class="enl-widget enl-widget--record">) +
          %(<div class="enl-widget__head">#{h(r[:label])}</div>#{facets}</div>)
      end

      def claim_row(claim)
        c = claim.is_a?(Hash) ? claim.transform_keys(&:to_sym) : {}
        verdict = c[:audit_verdict] ? %( <span class="enl-claim__verdict">#{h(c[:audit_verdict])}</span>) : ""
        conf = c[:confidence] ? %( <span class="enl-claim__conf">#{h(c[:confidence])}</span>) : ""
        %(<div class="enl-claim"><span class="enl-claim__key">#{h(c[:key])}</span>: ) +
          %(<span class="enl-claim__value">#{h(c[:value])}</span>#{conf}#{verdict}</div>)
      end
    end
  end
end
