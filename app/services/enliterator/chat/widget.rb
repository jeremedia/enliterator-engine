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

      # --- search / subject_search (same card-list shape) ---------------------
      def render_search(result)
        cards = Array(symize(result)[:results]).map do |item|
          i = symize(item)
          counts = [ ("#{h(i[:claim_count])} claims" if i[:claim_count]),
                     ("#{h(i[:visit_count])} visits" if i[:visit_count]) ].compact.join(" · ")
          %(<li class="enl-result"><div class="enl-result__label">#{h(i[:label])} ) +
            %(<span class="enl-result__type">#{h(i[:type])}</span></div>) +
            %(<div class="enl-result__excerpt">#{h(i[:excerpt])}</div>) +
            %(<div class="enl-result__counts">#{counts}</div></li>)
        end.join
        %(<div class="enl-widget enl-widget--results"><ul class="enl-results">#{cards}</ul></div>)
      end
      def render_subject_search(result) = render_search(result)

      # --- quote -------------------------------------------------------------
      def render_quote(result)
        r = symize(result)
        if r[:located] == false
          %(<div class="enl-widget enl-widget--quote enl-widget--quote-unlocated">) +
            %(<div class="enl-quote__flag">passage not located — showing head of source</div>) +
            %(<blockquote class="enl-quote">#{h(r[:passage])}</blockquote></div>)
        else
          %(<div class="enl-widget enl-widget--quote"><blockquote class="enl-quote">#{h(r[:passage])}</blockquote></div>)
        end
      end

      # --- connections -------------------------------------------------------
      def render_connections(result)
        r = symize(result)
        edges = Array(r[:edges]).map do |e|
          e = symize(e)
          %(<li class="enl-edge"><span class="enl-edge__key">#{h(e[:key])}</span> → #{h(e[:target])}</li>)
        end.join
        neighbors = Array(r[:neighbors])
        nb = if neighbors.empty? && r[:neighbors_state].to_s != "" && r[:neighbors_state].to_s != "ok"
               state_label = neighbor_state_label(r[:neighbors_state].to_s)
               %(<div class="enl-edge__degraded">neighbors unavailable — #{h(state_label)}</div>)
             else
               neighbors.map { |n| n = symize(n); %(<li class="enl-neighbor">#{h(n[:label])}</li>) }.join
             end
        %(<div class="enl-widget enl-widget--conn"><ul class="enl-edges">#{edges}</ul>#{nb}</div>)
      end

      def neighbor_state_label(state)
        case state
        when "no_embedding"  then "no embedding for this record"
        when "not_in_atlas"  then "not in the atlas yet"
        else                      state
        end
      end
    end
  end
end
