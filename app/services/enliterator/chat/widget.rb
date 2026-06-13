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

      # v0.29 citations: the record-identity data attributes the client harvests
      # to build the sources rail + inline chips. ADDITIVE — invisible in the
      # render, inert when federation is off (the client never runs). Every value
      # is h()-escaped (a data attribute is an XSS surface too); a missing field
      # emits no attribute (so the client's [data-enl-id] gate only fires when an
      # id is actually present). `entry` is the click-through path the tool
      # already computes (entry_path) — preferred over reconstructing it.
      def enl_data_attrs(type:, id:, label: nil, entry: nil)
        return "" if id.nil? || id.to_s.empty?
        attrs = +%( data-enl-type="#{h(type)}" data-enl-id="#{h(id)}")
        attrs << %( data-enl-label="#{h(label)}") unless label.nil? || label.to_s.empty?
        attrs << %( data-enl-entry="#{h(entry)}") unless entry.nil? || entry.to_s.empty?
        attrs
      end

      # named without a render_ prefix so render() can never dispatch to it — a
      # tool literally named "fallback" must not match this arity-2 method.
      # v0.29: the raw block is COLLAPSED — an unrendered tool announces itself
      # (rule 3, visible) without letting its JSON dominate the transcript.
      def fallback_html(tool_name, result)
        %(<div class="enl-widget enl-widget--raw"><details><summary class="enl-widget__head">#{h(tool_name)}</summary>) +
          %(<pre class="enl-widget__json">#{h(JSON.pretty_generate(result))}</pre></details></div>)
      end

      # --- record_entry ------------------------------------------------------
      def render_record_entry(result)
        r = symize(result)
        # v0.29: the record's identity rides on the root as data attributes (the
        # client harvests them to build the sources rail + an inline chip for this
        # record). `entry` is the tool's own click-through path. The visible
        # render is unchanged — these are inert attributes.
        data = enl_data_attrs(type: r[:type], id: r[:id], label: r[:label], entry: r[:entry])
        facets = (r[:claims_by_facet] || {}).map do |facet, claims|
          rows = Array(claims).map { |c| claim_row(c) }.join
          %(<div class="enl-widget__facet"><div class="enl-widget__facet-name">#{h(facet)}</div>#{rows}</div>)
        end.join
        %(<div class="enl-widget enl-widget--record"#{data}>) +
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
        # The search/subject_search tools emit hits under :records (NOT :results) —
        # reading the wrong key rendered an empty widget, so search-surfaced records
        # never cited/linked (only record_entry did). Read :records, :results fallback.
        r = symize(result)
        cards = Array(r[:records] || r[:results]).map do |item|
          i = symize(item)
          counts = [ ("#{h(i[:claim_count])} claims" if i[:claim_count]),
                     ("#{h(i[:visit_count])} visits" if i[:visit_count]) ].compact.join(" · ")
          # v0.29: each result card carries its record identity (type/id/label/
          # entry) so the client can number it in the sources rail and link it
          # through. `entry` is the tool's own path (search_card / subject_search
          # both emit it). Additive attributes — the visible card is unchanged.
          data = enl_data_attrs(type: i[:type], id: i[:id], label: i[:label], entry: i[:entry])
          %(<li class="enl-result"#{data}><div class="enl-result__label">#{h(i[:label])} ) +
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

      # --- collection_overview ----------------------------------------------
      # The self-portrait card: the shared stat-strip (four headline numbers),
      # facet chips, then the context tree and accuracy table tucked behind
      # collapsed details. `next:` is the model's map — never rendered.
      def render_collection_overview(result)
        r     = symize(result)
        stats = symize(r[:stats])
        strip = stat_strip([
          [ stats[:enliterated],     "enliterated" ],
          [ stats[:corpus],          "corpus" ],
          [ stats[:live_claims],     "live claims" ],
          [ stats[:vocabulary_keys], "vocabulary keys" ]
        ])

        chips = Array(r[:facets]).map { |f|
          f = symize(f)
          %(<span class="facet-chip">#{h(f[:facet])} · #{h(f[:tended_count])}</span>)
        }.join
        chips = %(<div class="stats-facets">#{chips}</div>) unless chips.empty?

        %(<div class="enl-widget enl-widget--overview">#{strip}#{chips}) +
          overview_contexts(r[:contexts]) +
          overview_accuracy(r[:accuracy]) + %(</div>)
      end

      def stat_strip(pairs)
        cells = pairs.map { |num, label|
          %(<div class="stat-cell"><div class="stat-num">#{h(num)}</div>) +
            %(<div class="stat-label">#{h(label)}</div></div>)
        }.join
        %(<div class="stats-strip"><div class="stats-grid">#{cells}</div></div>)
      end

      def overview_contexts(contexts)
        rows = Array(contexts).map { |c|
          c = symize(c)
          %(<tr><td>#{h(c[:key])}</td><td>#{h(c[:name])}</td><td>#{h(c[:members])}</td></tr>)
        }.join
        return "" if rows.empty?
        %(<details class="enl-overview__contexts"><summary>contexts</summary>) +
          %(<table><thead><tr><th>key</th><th>name</th><th>members</th></tr></thead>) +
          %(<tbody>#{rows}</tbody></table></details>)
      end

      def overview_accuracy(accuracy)
        rows = Array(accuracy).map { |a|
          a = symize(a)
          %(<tr><td>#{h(a[:facet])}</td><td>#{h(a[:tier])}</td>) +
            %(<td>#{h(a[:audited])}</td><td>#{h(a[:supported_rate])}</td><td>#{h(a[:contradicted])}</td></tr>)
        }.join
        return "" if rows.empty?
        %(<details class="enl-overview__accuracy"><summary>accuracy</summary>) +
          %(<table class="enl-accuracy"><thead><tr><th>facet</th><th>tier</th><th>audited</th><th>supported</th><th>contradicted</th></tr></thead>) +
          %(<tbody>#{rows}</tbody></table></details>)
      end

      # --- browse_subjects ---------------------------------------------------
      # The subject-heading index: each heading's key, then its top values as
      # term/count chips. values are [term, count] PAIRS. Up to 8 inline; the
      # rest fold into a "show all" details. Approximate counts get a visible
      # note (the v0.24 "≥" honesty). Empty headings → an honest empty state.
      HEADINGS_INLINE = 8

      def render_browse_subjects(result)
        r = symize(result)
        headings = Array(r[:headings])
        body = if headings.empty?
                 %(<div class="enl-headings__empty">no subject headings in this scope</div>)
               else
                 headings.map { |hd| heading_block(hd) }.join
               end
        %(<div class="enl-widget enl-widget--headings">#{body}</div>)
      end

      def heading_block(heading)
        hd     = symize(heading)
        values = Array(hd[:values])
        inline, rest = values.first(HEADINGS_INLINE), values.drop(HEADINGS_INLINE)
        approx = hd[:approximate] ? %( <span class="enl-headings__approx">≥ approximate counts</span>) : ""
        more   = rest.empty? ? "" :
                   %(<details class="enl-headings__more"><summary>show all (#{h(values.size)})</summary>) +
                     %(<div class="enl-headings__vals">#{headvals(rest)}</div></details>)
        %(<div class="enl-headings__heading"><div class="enl-headings__key">#{h(hd[:key])}#{approx}</div>) +
          %(<div class="enl-headings__vals">#{headvals(inline)}</div>#{more}</div>)
      end

      def headvals(pairs)
        Array(pairs).map { |pair|
          term, count = Array(pair)
          %(<span class="enl-headval">#{h(term)} <b>#{h(count)}</b></span>)
        }.join
      end

      # --- vocabulary --------------------------------------------------------
      # Per facet: name + a tier chip + a scheduled/unscheduled marker, then the
      # term: meaning rows (required terms flagged). terms nil/absent → an
      # explicit open-facet line (rule 3: a blank vocabulary is silence).
      def render_vocabulary(result)
        r = symize(result)
        facets = Array(r[:facets]).map { |f| vocab_facet(f) }.join
        %(<div class="enl-widget enl-widget--vocab">#{facets}</div>)
      end

      def vocab_facet(facet)
        f        = symize(facet)
        sched    = f[:scheduled] ? "scheduled" : "unscheduled"
        required = Array(f[:required]).map(&:to_s)
        head = %(<span class="enl-vocab__name">#{h(f[:facet])}</span>) +
               %( <span class="chip tier">#{h(f[:tier])}</span>) +
               %( <span class="enl-vocab__sched">#{h(sched)}</span>)
        terms = f[:terms]
        body  = if terms.is_a?(Hash) && !terms.empty?
                  terms.map { |term, meaning| vocab_term(term, meaning, required) }.join
                else
                  %(<div class="enl-vocab__term">open facet (unconstrained vocabulary)</div>)
                end
        %(<div class="enl-vocab__facet"><div class="enl-vocab__head">#{head}</div>#{body}</div>)
      end

      def vocab_term(term, meaning, required)
        klass = required.include?(term.to_s) ? "enl-vocab__term enl-vocab__term--req" : "enl-vocab__term"
        m = meaning.nil? || meaning.to_s.empty? ? "" : ": #{h(meaning)}"
        %(<span class="#{klass}">#{h(term)}#{m}</span>)
      end

      # --- recent_activity ---------------------------------------------------
      # The diary card: the headline as a lead line, then visits-by-tier and
      # failures behind collapsed details — each failure's error TEXT visible
      # (rule 3). An honest empty state when the window was quiet.
      def render_recent_activity(result)
        r        = symize(result)
        visits   = symize(r[:visits])
        failures = symize(r[:failures])
        quiet    = visits[:total].to_i.zero? && failures[:count].to_i.zero?

        lead = %(<div class="enl-activity__headline">#{h(r[:headline])}</div>)
        body = if quiet
                 %(<div class="enl-activity__empty">no activity in this window</div>)
               else
                 activity_tiers(visits[:by_tier]) + activity_failures(failures)
               end
        %(<div class="enl-widget enl-widget--activity">#{lead}#{body}</div>)
      end

      def activity_tiers(by_tier)
        by_tier = symize(by_tier)
        return "" if by_tier.empty?
        rows = by_tier.map { |tier, n| %(<li class="enl-activity__tier">#{h(tier)} <b>#{h(n)}</b></li>) }.join
        %(<details class="enl-activity__visits"><summary>visits by tier</summary>) +
          %(<ul class="enl-activity__tiers">#{rows}</ul></details>)
      end

      def activity_failures(failures)
        f     = symize(failures)
        count = f[:count].to_i
        return "" if count.zero?
        items = Array(f[:sample]).map { |s|
          s = symize(s)
          %(<li class="enl-activity__failure"><span class="enl-activity__where">#{h(s[:record])} · #{h(s[:facet])} · #{h(s[:tier])}</span>) +
            %(<div class="enl-activity__error">#{h(s[:error])}</div></li>)
        }.join
        more = f[:truncated] ? %(<div class="enl-activity__truncated">…more failures than shown</div>) : ""
        %(<details class="enl-activity__failures"><summary>failures (#{h(count)})</summary>) +
          %(<ul class="enl-activity__failure-list">#{items}</ul>#{more}</details>)
      end
    end
  end
end
