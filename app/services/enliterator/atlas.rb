module Enliterator
  # v0.21: the ATLAS — the enliterated collection drawn as a graph.
  #
  # The claim store IS a labeled property graph: records are nodes, and a
  # claim whose value names things (an advisor, an agency, a superseded EO,
  # a related report) is a typed edge — the controlled vocabulary is the edge
  # taxonomy (the librarian's syndetic structure, visualized). What makes it
  # more than a generic knowledge graph: every edge carries its provenance
  # (tier, confidence, when it was asserted, the audit verdict where one
  # exists), and the graph GROWS as the heartbeat tends — each edge is
  # stamped with its claim's created_at so the surface can replay the
  # collection learning.
  #
  # Host-generic by design — no per-host configuration:
  # - A key is ENTITY-BEARING when its values are short strings (median
  #   extracted term under SHORT chars). Prose keys (summary, methodology)
  #   fall out naturally.
  # - Strings resolve to RECORDS through an index of unique IDENTIFIER claim
  #   values (keys named like control numbers — eo_number, report_number; the
  #   cataloger's identifiers) plus record titles: an EO's `supersedes:
  #   ["13129"]` finds the record whose `eo_number` claim is "13129".
  #   Unresolved strings become ENTITY nodes, deduped by normalized string —
  #   including referenced-but-untended works: the visible frontier.
  # - Identifier claims feed the index and self-resolve, so they draw no
  #   self-edges; attribute claims (advisor, cluster) never enter the index
  #   and always draw.
  module Atlas
    module_function

    SHORT = 90          # max chars for an entity-bearing term
    TTL   = 5.minutes   # the v0.20 rollup idiom: heartbeat-keyed + short TTL
    CACHE_VERSION = "v3"
    UNRESOLVED_ENTITY_CROWD_MULTIPLIER = 4
    UNRESOLVED_ENTITY_MIN_COUNT = 2
    RENDERER = "sigma@3.0.3+graphology@0.26.0+forceatlas2@0.10.1"
    OVERVIEW_NODE_CAP = 240
    OVERVIEW_EDGE_CAP = 420
    OVERVIEW_SOURCE_CAP = 540
    OVERVIEW_RECORD_CANDIDATE_CAP = 260
    FOCUS_NODE_CAP = 250
    PRESENTATION_MODES = %w[overview explore focus].freeze
    EDGE_CATEGORIES = %w[context citation authority agent subject evidence other].freeze

    # Keys whose values IDENTIFY their record (control numbers, in the
    # cataloger's sense). Only these — plus record titles — feed the
    # resolution index; an attribute claim (advisor, thematic_cluster) must
    # never self-resolve into silence.
    IDENTIFIER_KEY_RX = /(^|_)(number|no|id|code|doi|isbn|issn|identifier)(_|$)/

    # v0.4X (Stage 1): focus mode accepts an Ego-lens opts bundle —
    # depth (1–3) + server-side typed-edge filters (min_confidence/audit/
    # categories/since/until). Captured as **opts so the no-opts path is
    # byte-identical (empty opts ⇒ no cache fragment ⇒ unchanged key).
    def build(context: nil, node_cap: nil, mode: nil, focus: nil, **opts)
      selected_mode = normalize_mode(mode)
      requested_cap = node_cap || Enliterator.configuration.atlas_node_cap
      cap = presentation_source_cap(selected_mode, requested_cap)
      key = [ "enliterator/atlas", CACHE_VERSION, selected_mode, focus.presence || "none",
              context&.key || "root", cap,
              "hb#{Enliterator::Heartbeat.maximum(:id) || 0}" ]
      frag = focus_cache_fragment(opts)
      key << "f:#{frag}" if frag
      Rails.cache.fetch(key.join("/"), expires_in: TTL) do
        assemble(context: context, node_cap: cap, mode: selected_mode, focus: focus, **opts)
      end
    end

    # The uncached computation. Returns { nodes:, edges:, meta: }.
    def assemble(context: nil, node_cap: nil, mode: nil, focus: nil, **opts)
      selected_mode = normalize_mode(mode)
      cap    = node_cap || Enliterator.configuration.atlas_node_cap
      claims = claims_for_mode(context, selected_mode).to_a
      return present_atlas(empty_atlas(context), mode: selected_mode, focus: focus, opts: opts) if claims.empty?

      # v0.26.1: ANALYTICAL ENTRIES ROLL UP. The atlas draws WORKS — a part's
      # claims (cited_works, index_terms, the deep read's notes) contribute
      # their edges to the parent record's node, never a node of their own.
      # Without this, one deep-read pilot (940 parts, 8K part claims) flooded
      # the node cap with part nodes that have no context membership — no
      # gravity well — and the layout exploded (found live, 2026-06-11).
      part_parent = part_parents(claims)

      by_record   = claims.group_by { |c| record_key_for(c, part_parent) }
      labels      = materialize_labels(by_record.keys)
      record_meta = atlas_record_meta(by_record)
      verdicts    = audit_verdicts(claims)

      nodes      = {}   # id => node hash
      edges      = {}   # [s, t, key] => edge hash (deduped; weight = max confidence)
      index      = resolution_index(claims, by_record, labels, part_parent)
      extracted  = extracted_terms_by_claim(claims, context: context)
      bearing    = entity_bearing_keys_from(claims, extracted)
      unresolved = drawable_unresolved_entities(claims, extracted, bearing, index, cap)
      warnings   = unresolved[:warnings]

      # Record nodes (label, genre group, first-claim timestamp, drill-down path).
      by_record.each do |(type, id), cs|
        meta = record_meta[[ type, id ]]
        ctx  = meta[:context]
        nodes[record_node_id(type, id)] = {
          id: record_node_id(type, id), kind: "record",
          label: record_label(labels, type, id),
          group: ctx&.key || "root",
          size: cs.size,
          at: meta[:at].to_i,
          path: "status/#{type}/#{id}"
        }
      end

      # Context diamonds + membership edges (the layout's gravity wells).
      by_record.each do |(type, id), cs|
        meta = record_meta[[ type, id ]]
        ctx = meta[:context]
        next unless ctx
        cid = "c:#{ctx.key}"
        nodes[cid] ||= { id: cid, kind: "context", label: ctx.name || ctx.key,
                         group: ctx.key, size: 0, at: meta[:at].to_i }
        nodes[cid][:size] += 1
        ekey = [ record_node_id(type, id), cid, "in-context" ]
        edges[ekey] ||= { s: ekey[0], t: cid, key: "in-context", w: 0.2,
                          at: meta[:at].to_i }
      end

      # Typed edges from entity-bearing claims (a part's edges source from
      # its PARENT work's node — the roll-up).
      claims.each do |c|
        next unless bearing.include?(c.key)
        source = record_node_id(*record_key_for(c, part_parent))
        extracted[c.id].each do |term|
          norm   = term.downcase.strip
          target = index[norm]
          next if target == source                       # identity self-reference
          unless target
            next unless unresolved[:terms].nil? || unresolved[:terms].include?(norm)
            target = "e:#{norm}"
            nodes[target] ||= { id: target, kind: "entity", label: term,
                                group: c.key, size: 0, at: c.created_at.to_i }
            nodes[target][:size] += 1
            nodes[target][:at] = [ nodes[target][:at], c.created_at.to_i ].min
          end
          ekey = [ source, target, c.key ]
          edge = (edges[ekey] ||= { s: source, t: target, key: c.key, w: 0.0,
                                    at: c.created_at.to_i, tier: c.tier })
          edge[:w]  = [ edge[:w], c.confidence.to_f ].max
          edge[:at] = [ edge[:at], c.created_at.to_i ].min
          edge[:verdict] = verdicts[c.id] if verdicts[c.id]
        end
      end

      atlas = apply_cap(nodes, edges, cap, claims, context, warnings: warnings)
      present_atlas(atlas, mode: selected_mode, focus: focus, opts: opts)
    end

    # Inspector data for one node: its live claims with provenance, plus any
    # open lacunae (known gaps). Records only carry claims/lacunae; entity nodes
    # return an empty shell and the client falls back to its edge summary.
    # (Named to match the inspector contract; shadows Object#inspect on this
    # module — harmless, nothing inspects the module itself, and the required
    # kwargs make an accidental bare call fail loudly rather than silently.)
    def inspect(type:, id:, context: nil)
      klass = type.to_s.safe_constantize
      rec   = klass&.where(klass.primary_key => id)&.first if klass
      label = rec && [ "title", "name" ].filter_map { |c| rec[c] if klass.column_names.include?(c) }.find(&:present?)

      claims = Enliterator::Claim.live.understanding
                 .where(tendable_type: type.to_s, tendable_id: id.to_s)
      claims = claims.where(context_id: context.scope_ids) if context
      verdicts = audit_verdicts(claims.to_a)

      claim_rows = claims.order(:key).map do |c|
        { key: c.key, value: c.value, tier: c.tier, confidence: c.confidence.to_f,
          asserted_at: c.created_at.to_i, verdict: verdicts[c.id] }.compact
      end

      lacuna_rows =
        if Enliterator.configuration.record_lacunae
          Enliterator::Lacuna.open.where(tendable_type: type.to_s, tendable_id: id.to_s)
                             .order(:key).map { |l| { key: l.key, diagnosis: l.diagnosis, note: l.note }.compact }
        else
          []
        end

      { node: { type: type.to_s, id: id.to_s, kind: "record",
                label: label.presence || "#{type} ##{id}", path: "status/#{type}/#{id}" },
        claims: claim_rows, lacunae: lacuna_rows }
    end

    def renderer_bundle
      @renderer_bundle ||= File.read(
        Enliterator::Engine.root.join("lib/enliterator/vendor/atlas_renderer.bundle.js")
      ).gsub("</script", "<\\/script")
    end

    # ---- presentation modes ----------------------------------------------

    def normalize_mode(mode)
      value = mode.to_s.presence || "explore"
      PRESENTATION_MODES.include?(value) ? value : "explore"
    end

    def presentation_source_cap(mode, cap)
      mode == "overview" ? [ cap, OVERVIEW_SOURCE_CAP ].min : cap
    end

    def present_atlas(atlas, mode:, focus: nil, opts: {})
      working = {
        nodes: atlas[:nodes].map(&:dup),
        edges: atlas[:edges].map(&:dup),
        meta:  atlas[:meta].dup
      }
      annotate_atlas!(working)

      case mode
      when "overview"
        overview_atlas(working)
      when "focus"
        focus_atlas(working, focus, opts)
      else
        finalize_presentation!(working, mode: "explore", focus: focus)
      end
    end

    def annotate_atlas!(atlas)
      nodes = atlas[:nodes]
      edges = atlas[:edges]
      by_id = nodes.index_by { |n| n[:id] }
      degree = Hash.new(0)

      edges.each_with_index do |edge, idx|
        edge[:id] ||= "a:#{idx}:#{edge[:s]}:#{edge[:t]}:#{edge[:key]}"
        edge[:category] = edge_category(edge[:key])
        degree[edge[:s]] += 1
        degree[edge[:t]] += 1
      end

      top_record_ids = nodes.select { |n| n[:kind] == "record" }
                            .sort_by { |n| [ -degree[n[:id]], n[:label].to_s ] }
                            .first(80)
                            .map { |n| n[:id] }
                            .to_set
      top_bridge_ids = nodes.select { |n| n[:kind] == "entity" && degree[n[:id]] >= 2 }
                            .sort_by { |n| [ -degree[n[:id]], -n[:size].to_i, n[:label].to_s ] }
                            .first(100)
                            .map { |n| n[:id] }
                            .to_set

      nodes.each do |node|
        node[:degree] = degree[node[:id]]
        node[:label_priority] =
          if node[:kind] == "context"
            100
          elsif top_bridge_ids.include?(node[:id])
            80
          elsif top_record_ids.include?(node[:id])
            60
          else
            0
          end
      end

      seed_positions!(nodes, edges, by_id)
      atlas[:meta][:renderer] = RENDERER
      atlas[:meta][:edge_categories] = EDGE_CATEGORIES
      atlas
    end

    def overview_atlas(atlas)
      nodes = atlas[:nodes]
      edges = atlas[:edges]
      by_id = nodes.index_by { |n| n[:id] }
      degree = nodes.to_h { |n| [ n[:id], n[:degree].to_i ] }
      selected = Set.new

      contexts = nodes.select { |n| n[:kind] == "context" }
      contexts.each { |n| selected << n[:id] }

      grouped_records = nodes.select { |n| n[:kind] == "record" }.group_by { |n| n[:group] || "root" }
      per_group = [ [ (130.0 / [ grouped_records.size, 1 ].max).ceil, 18 ].max, 55 ].min
      grouped_records.each_value do |records|
        records.sort_by { |n| [ -degree[n[:id]], n[:label].to_s ] }
               .first(per_group)
               .each { |n| selected << n[:id] }
      end

      edges.select { |e| e[:category] != "context" && by_id[e[:s]]&.dig(:kind) == "record" && by_id[e[:t]]&.dig(:kind) == "record" }
           .sort_by { |e| [ -edge_weight(e), e[:key].to_s ] }
           .first(80)
           .each { |e| selected << e[:s]; selected << e[:t] }

      nodes.select { |n| n[:kind] == "entity" && (n[:size].to_i >= 2 || degree[n[:id]] >= 2) }
           .sort_by { |n| [ -degree[n[:id]], -n[:size].to_i, n[:label].to_s ] }
           .first(70)
           .each { |n| selected << n[:id] }

      nodes.select { |n| n[:kind] == "record" && !selected.include?(n[:id]) }
           .sort_by { |n| [ -degree[n[:id]], n[:label].to_s ] }
           .each do |n|
             break if selected.size >= OVERVIEW_NODE_CAP
             selected << n[:id]
           end

      selected = selected.first(OVERVIEW_NODE_CAP).to_set if selected.size > OVERVIEW_NODE_CAP
      filter_presented_atlas(atlas, selected, mode: "overview", edge_cap: OVERVIEW_EDGE_CAP)
    end

    def focus_atlas(atlas, focus, opts = {})
      focus_id = focus.to_s.presence
      return overview_atlas(with_warning(atlas, "focus mode needs a selected node id")) unless focus_id

      nodes = atlas[:nodes]
      ids = nodes.map { |n| n[:id] }.to_set
      return overview_atlas(with_warning(atlas, "selected focus node is not in the current atlas")) unless ids.include?(focus_id)

      edges = filtered_focus_edges(atlas[:edges], opts)
      depth = [ [ (opts[:depth].presence || 1).to_i, 1 ].max, 3 ].min

      degree = nodes.to_h { |n| [ n[:id], n[:degree].to_i ] }
      selected = Set[focus_id]
      adjacent_edges = edges.select { |e| e[:s] == focus_id || e[:t] == focus_id }
      adjacent_edges.sort_by { |e| [ e[:category] == "context" ? 1 : 0, -edge_weight(e), e[:key].to_s ] }
                    .each do |edge|
                      break if selected.size >= FOCUS_NODE_CAP
                      selected << (edge[:s] == focus_id ? edge[:t] : edge[:s])
                    end

      # depth 1 = adjacency + one bridge-frontier hop (the v0.21 default — one
      # pass reproduces it byte-identically); each extra depth repeats the
      # frontier expansion over the FILTERED edges, growing the neighborhood.
      depth.times do
        frontier = edges.select { |e| selected.include?(e[:s]) ^ selected.include?(e[:t]) }
        frontier.sort_by do |edge|
          other = selected.include?(edge[:s]) ? edge[:t] : edge[:s]
          [ edge[:category] == "context" ? 1 : 0, -degree[other], -edge_weight(edge), edge[:key].to_s ]
        end.each do |edge|
          break if selected.size >= FOCUS_NODE_CAP
          other = selected.include?(edge[:s]) ? edge[:t] : edge[:s]
          selected << other if degree[other].to_i >= 2 || edge[:category] != "context"
        end
      end

      filtered_atlas = atlas.merge(edges: edges)
      result = filter_presented_atlas(filtered_atlas, selected, mode: "focus", focus: focus_id, edge_cap: OVERVIEW_EDGE_CAP)
      result[:meta][:depth] = depth
      result[:meta][:filters] = focus_filters_meta(opts)
      result
    end

    # Apply the Ego-lens typed-edge filters to the candidate edges before
    # neighborhood selection. No active filter ⇒ the same array reference back
    # (byte-identical default focus). edge_weight() floors un-weighted edges at
    # 0.5, so in-context edges (w=0.2) drop under any min_confidence above 0.2.
    def filtered_focus_edges(all_edges, opts)
      edges = all_edges
      if opts[:min_confidence].to_f > 0
        mc = opts[:min_confidence].to_f
        edges = edges.select { |e| edge_weight(e) >= mc }
      end
      cats = filter_categories(opts)
      if cats.any?
        set = cats.to_set
        edges = edges.select { |e| set.include?(e[:category].to_s) }
      end
      case opts[:audit].to_s
      when "audited"
        edges = edges.select { |e| e[:verdict].present? }
      when "supported", "unsupported"
        edges = edges.select { |e| e[:verdict].to_s.end_with?(":#{opts[:audit]}") }
      end
      since = opts[:since].to_i
      edges = edges.select { |e| e[:at].to_i >= since } if since > 0
      untl = opts[:until].to_i
      edges = edges.select { |e| e[:at].to_i <= untl } if untl > 0
      edges
    end

    # The active filter state echoed in meta so the client shows what's applied.
    def focus_filters_meta(opts)
      { "min_confidence" => opts[:min_confidence].to_f,
        "audit" => opts[:audit].to_s.presence || "any",
        "categories" => filter_categories(opts),
        "since" => opts[:since].to_i,
        "until" => opts[:until].to_i }
    end

    # A stable cache fragment for non-default focus filters, or nil when none —
    # nil keeps the cache key byte-identical to the pre-Stage-1 format.
    def focus_cache_fragment(opts)
      parts = []
      parts << "d#{opts[:depth].to_i}"            if opts[:depth].present? && opts[:depth].to_i > 1
      parts << "mc#{opts[:min_confidence].to_f}"  if opts[:min_confidence].present? && opts[:min_confidence].to_f > 0
      parts << "a#{opts[:audit]}"                 if opts[:audit].present? && opts[:audit].to_s != "any"
      cats = filter_categories(opts).sort
      parts << "c#{cats.join('+')}"               if cats.any?
      parts << "s#{opts[:since].to_i}"            if opts[:since].present? && opts[:since].to_i > 0
      parts << "u#{opts[:until].to_i}"            if opts[:until].present? && opts[:until].to_i > 0
      parts.any? ? parts.join(",") : nil
    end

    # Categories arrive as an array or a CSV string (controller params); normalize.
    def filter_categories(opts)
      Array(opts[:categories]).flat_map { |c| c.to_s.split(",") }.map(&:strip).reject(&:blank?)
    end

    def filter_presented_atlas(atlas, selected, mode:, edge_cap:, focus: nil)
      selected_nodes = atlas[:nodes].select { |n| selected.include?(n[:id]) }
      selected_edges = atlas[:edges].select { |e| selected.include?(e[:s]) && selected.include?(e[:t]) }
      visible_edges = selected_edges.sort_by do |edge|
        context_penalty = edge[:category] == "context" ? 1 : 0
        [ context_penalty, -edge_weight(edge), edge[:key].to_s, edge[:id].to_s ]
      end.first(edge_cap)

      filtered = {
        nodes: selected_nodes,
        edges: visible_edges,
        meta: atlas[:meta].dup.merge(
          source_node_count: atlas[:nodes].size,
          source_edge_count: atlas[:edges].size
        )
      }
      finalize_presentation!(filtered, mode: mode, focus: focus)
    end

    def finalize_presentation!(atlas, mode:, focus: nil)
      atlas[:meta][:mode] = mode
      atlas[:meta][:focus] = focus if focus.present?
      atlas[:meta][:display_nodes] = atlas[:nodes].size
      atlas[:meta][:display_edges] = atlas[:edges].size
      atlas
    end

    def with_warning(atlas, warning)
      atlas[:meta][:warnings] = Array(atlas[:meta][:warnings]) + [ warning ]
      atlas
    end

    def edge_weight(edge)
      edge[:w].to_f.nonzero? || 0.5
    end

    def edge_category(key)
      k = key.to_s
      return "context" if k == "in-context"
      return "citation" if k.match?(/cited|citation|bibliograph|reference|source|supersed|related_(report|work)|works?\z/)
      return "authority" if k.match?(IDENTIFIER_KEY_RX) || k.match?(/authority|authorized|control|lccn|call_number|classification/)
      return "agent" if k.match?(/advisor|author|agency|agencies|department|office|committee|sponsor|witness|person|actor|organization|institution/)
      return "subject" if k.match?(/subject|keyword|index_terms|topic|theme|cluster|tag|issue|domain/)
      return "evidence" if k.match?(/evidence|finding|method|basis|quote|passage|excerpt|indicator|risk|rationale/)
      "other"
    end

    def seed_positions!(nodes, edges, by_id)
      context_nodes = nodes.select { |n| n[:kind] == "context" }.sort_by { |n| n[:id] }
      context_nodes.each_with_index do |node, idx|
        angle = context_nodes.length <= 1 ? 0.0 : (-Math::PI / 2.0) + (idx.to_f / context_nodes.length) * Math::PI * 2
        radius = context_nodes.length <= 1 ? 0.0 : 420.0
        node[:x] = (Math.cos(angle) * radius).round(3)
        node[:y] = (Math.sin(angle) * radius * 0.72).round(3)
      end

      hub_for = {}
      edges.each do |edge|
        next unless edge[:category] == "context"
        source = by_id[edge[:s]]
        target = by_id[edge[:t]]
        if source&.dig(:kind) == "record" && target&.dig(:kind) == "context"
          hub_for[source[:id]] = target
        elsif target&.dig(:kind) == "record" && source&.dig(:kind) == "context"
          hub_for[target[:id]] = source
        end
      end

      edges.each do |edge|
        source = by_id[edge[:s]]
        target = by_id[edge[:t]]
        next unless source && target
        if target[:kind] == "entity" && hub_for[source[:id]]
          hub_for[target[:id]] ||= hub_for[source[:id]]
        elsif source[:kind] == "entity" && hub_for[target[:id]]
          hub_for[source[:id]] ||= hub_for[target[:id]]
        end
      end

      fallback_groups = nodes.reject { |n| n[:kind] == "context" }.map { |n| n[:group] || "root" }.uniq.sort
      group_anchor = fallback_groups.each_with_index.to_h do |group, idx|
        angle = fallback_groups.length <= 1 ? 0.0 : (-Math::PI / 2.0) + (idx.to_f / fallback_groups.length) * Math::PI * 2
        [ group, { x: Math.cos(angle) * 360.0, y: Math.sin(angle) * 260.0 } ]
      end

      nodes.each do |node|
        next if node[:kind] == "context"
        hub = hub_for[node[:id]]
        anchor = hub || group_anchor[node[:group] || "root"] || { x: 0.0, y: 0.0 }
        min_radius = node[:kind] == "record" ? 55.0 : 115.0
        span = node[:kind] == "record" ? 210.0 : 360.0
        offset = seeded_offset(node[:id], min_radius, span)
        node[:x] = (anchor[:x].to_f + offset[:x]).round(3)
        node[:y] = (anchor[:y].to_f + offset[:y]).round(3)
      end
    end

    def seeded_offset(key, min_radius, span)
      h = stable_hash(key)
      angle = (h.to_f / 4_294_967_296.0) * Math::PI * 2
      radius = min_radius + (((h >> 8) % 1_000).to_f / 1_000.0) * span
      { x: Math.cos(angle) * radius, y: Math.sin(angle) * radius * 0.82 }
    end

    def stable_hash(value)
      value.to_s.each_byte.reduce(2_166_136_261) do |hash, byte|
        ((hash ^ byte) * 16_777_619) & 0xffffffff
      end
    end

    # ---- claim scope -----------------------------------------------------

    # Live claims that ARE understanding (Claim.understanding — extracted to
    # the model in v0.24 so the Catalog reads the same definition), read
    # cumulatively up the context path.
    def claims_for_mode(context, mode)
      mode == "overview" ? overview_claims(context) : understanding_claims(context)
    end

    def understanding_scope(context)
      scope = Enliterator::Claim.live.understanding
      scope = scope.where(context_id: context.scope_ids) if context
      scope
    end

    def understanding_claims(context)
      understanding_scope(context).preload(:context)
    end

    # Overview is a finding-aid view, not the exhaustive graph. Build it from
    # high-signal record candidates per context so the first root fetch does not
    # pay to materialize every one-off analytical access point before pruning.
    # Explore mode remains the backward-compatible full capped graph.
    def overview_claims(context)
      base = understanding_scope(context)
      context_ids = base.reselect(:context_id).distinct.pluck(:context_id)
      context_ids = [ nil ] if context_ids.empty?
      per_context = [
        (OVERVIEW_RECORD_CANDIDATE_CAP.to_f / [ context_ids.size, 1 ].max).ceil,
        80
      ].max
      per_context = [ per_context, OVERVIEW_RECORD_CANDIDATE_CAP ].min

      pairs = context_ids.flat_map do |context_id|
        scoped = context_id.nil? ? base.where(context_id: nil) : base.where(context_id: context_id)
        scoped.group(:tendable_type, :tendable_id)
              .order(Arel.sql("COUNT(*) DESC"))
              .limit(per_context)
              .count
              .keys
      end.uniq

      limited = nil
      pairs.group_by(&:first).each do |type, typed_pairs|
        rel = base.where(tendable_type: type, tendable_id: typed_pairs.map(&:second))
        limited = limited ? limited.or(rel) : rel
      end
      (limited || base.none).preload(:context)
    end

    # ---- resolution ------------------------------------------------------

    # {normalized short string => record node id}, UNIQUE values only — a
    # collision means the string can't name one record, so it stays an entity.
    # Sources: IDENTIFIER claim values (eo_number "13129") + record titles.
    # Part claims resolve to their PARENT work's node (the roll-up).
    def resolution_index(claims, by_record, labels, part_parent = {})
      index, seen = {}, {}
      add = lambda do |str, node_id|
        norm = str.to_s.downcase.strip
        return if norm.blank? || norm.length > SHORT
        if seen.key?(norm)
          index.delete(norm) unless seen[norm] == node_id
        else
          seen[norm] = node_id
          index[norm] = node_id
        end
      end
      claims.each do |c|
        next unless c.key.match?(IDENTIFIER_KEY_RX)
        next unless c.value.is_a?(String) && c.value.length <= SHORT
        add.call(c.value, record_node_id(*record_key_for(c, part_parent)))
      end
      by_record.each_key do |(type, id)|
        title = record_label(labels, type, id)
        add.call(title, record_node_id(type, id))
      end
      index
    end

    # ---- entity extraction -----------------------------------------------

    # A key contributes edges when the MEDIAN of its extracted terms is short
    # — prose keys (summary, key_findings) fall out without a denylist.
    def entity_bearing_keys(claims)
      entity_bearing_keys_from(claims, extracted_terms_by_claim(claims))
    end

    def entity_bearing_keys_from(claims, extracted)
      lengths = Hash.new { |h, k| h[k] = [] }
      claims.each { |c| extracted[c.id].each { |t| lengths[c.key] << t.length } }
      lengths.select { |_, ls| ls.any? && median(ls) <= SHORT }.keys.to_set
    end

    # v0.45: name-bearing claim values are resolved to their canonical (preferred)
    # form HERE — the single chokepoint, so the resolution index, the unresolved
    # cap, and the edge loop all see one entity per person (variant spellings
    # collapse to a single labeled node). Empty name_authority_keys ⇒ no resolution
    # and no query ⇒ byte-identical.
    def extracted_terms_by_claim(claims, context: nil)
      name_keys = Enliterator.configuration.name_authority_keys.map(&:to_s)
      authority = name_keys.present? ? Enliterator::NameAuthority.map_for(context: context) : {}
      claims.each_with_object({}) do |c, h|
        terms = extract_terms(c.value)
        terms = terms.map { |t| t.is_a?(String) ? (authority[t] || t) : t } if name_keys.include?(c.key)
        h[c.id] = terms
      end
    end

    # In large, deeply read collections, index_terms/cited_works can introduce
    # tens of thousands of one-off labels. They are useful catalog access
    # points, but as Atlas entity nodes they dominate build time and then get
    # discarded by the node cap. Keep repeated unresolved labels; record-resolved
    # terms are handled separately and are never filtered here.
    def drawable_unresolved_entities(claims, extracted, bearing, index, cap)
      counts = Hash.new(0)
      claims.each do |c|
        next unless bearing.include?(c.key)
        extracted[c.id].each do |term|
          norm = term.downcase.strip
          counts[norm] += 1 unless index.key?(norm)
        end
      end

      crowd_limit = cap * UNRESOLVED_ENTITY_CROWD_MULTIPLIER
      return { terms: nil, warnings: [] } if counts.size <= crowd_limit

      kept = counts.select { |_, count| count >= UNRESOLVED_ENTITY_MIN_COUNT }
                   .sort_by { |norm, count| [ -count, norm ] }
                   .first(crowd_limit)
                   .map(&:first)
                   .to_set
      omitted = counts.size - kept.size
      { terms: kept,
        warnings: [ "showing #{kept.size} repeated unresolved entity labels; " \
                    "omitted #{omitted} one-off labels before node cap" ] }
    end

    # Tolerant of the shapes claims actually hold: string, array of strings,
    # array of {type:, designation:} hashes, bare hash. Blank and over-long
    # elements are skipped individually.
    def extract_terms(value)
      raw =
        case value
        when String then [ value ]
        when Array  then value.flat_map { |v| extract_terms(v) }
        when Hash   then [ value["designation"] || value["name"] ||
                           value.values.find { |v| v.is_a?(String) } ]
        else []
        end
      raw.compact.map(&:to_s).map(&:strip)
         .reject { |s| s.blank? || s.length > SHORT }
    end

    def median(arr)
      s = arr.sort
      s[s.size / 2]
    end

    # ---- assembly helpers --------------------------------------------------

    # {part_id(String) => [parent_type, parent_id]} for every Part claim in
    # the build — one query, only when parts are present.
    def part_parents(claims)
      part_ids = claims.select { |c| c.tendable_type == "Enliterator::Part" }
                       .map(&:tendable_id).uniq
      return {} if part_ids.empty?
      Enliterator::Part.where(id: part_ids)
                       .pluck(:id, :record_type, :record_id)
                       .each_with_object({}) { |(id, t, rid), h| h[id.to_s] = [ t, rid.to_s ] }
    end

    # The node a claim belongs to: its record — or its record's PARENT when
    # the claim sits on an analytical entry. A part whose parent vanished
    # falls back to itself (materialize labels it honestly by id).
    def record_key_for(claim, part_parent)
      if claim.tendable_type == "Enliterator::Part"
        part_parent[claim.tendable_id.to_s] || [ claim.tendable_type, claim.tendable_id ]
      else
        [ claim.tendable_type, claim.tendable_id ]
      end
    end

    def record_node_id(type, id) = "r:#{type}:#{id}"

    def record_label(labels, type, id)
      labels[[ type, id.to_s ]].presence || "#{type} ##{id}"
    end

    # The record's most specific context among its claims (claims carry their
    # context); nil means the record is only read at root.
    def dominant_context(claims)
      claims.filter_map(&:context).max_by { |ctx| ctx.path_ids.size }
    end

    def materialize(keys)
      keys.group_by(&:first).each_with_object({}) do |(type, pairs), h|
        klass = type.safe_constantize
        next unless klass
        ids = pairs.map(&:last)
        klass.where(klass.primary_key => ids).each do |rec|
          h[[ type, rec[klass.primary_key].to_s ]] = rec
        end
      end
    end

    def materialize_labels(keys)
      keys.group_by(&:first).each_with_object({}) do |(type, pairs), h|
        klass = type.safe_constantize
        next unless klass
        pk = klass.primary_key
        ids = pairs.map(&:last)
        label_columns = [ "title", "name" ].select { |column| klass.column_names.include?(column) }

        if label_columns.any?
          klass.where(pk => ids).pluck(pk, *label_columns).each do |row|
            id, *values = row
            h[[ type, id.to_s ]] = values.find(&:present?)
          end
        else
          ids.each { |id| h[[ type, id.to_s ]] = "#{type} ##{id}" }
        end
      end
    end

    def atlas_record_meta(by_record)
      by_record.transform_values do |claims|
        {
          context: dominant_context(claims),
          at: claims.min_by(&:created_at).created_at
        }
      end
    end

    # Latest audit verdict per claim, human outranking examiner (the anchor
    # is the only independent ground truth — same precedence as Audit.accuracy).
    # Instrument-scoped (v0.26): agent flags carry no verdict weight here.
    def audit_verdicts(claims)
      Enliterator::Audit.instrument.where(claim_id: claims.map(&:id)).order(:created_at)
                        .each_with_object({}) do |a, h|
        next if h[a.claim_id]&.start_with?("human:") && a.source == "examiner"
        h[a.claim_id] = "#{a.source}:#{a.verdict}"
      end
    end

    # Over the cap: keep the most-connected nodes and say so. Edges touching
    # a dropped node are dropped with it.
    def apply_cap(nodes, edges, cap, claims, context, warnings: [])
      warnings = warnings.dup
      if nodes.size > cap
        degree = Hash.new(0)
        edges.each_value { |e| degree[e[:s]] += 1; degree[e[:t]] += 1 }
        kept = nodes.keys.sort_by { |id| -degree[id] }.first(cap).to_set
        warnings << "showing the #{cap} most-connected of #{nodes.size} nodes — " \
                    "view through a context to see a neighborhood whole"
        nodes = nodes.slice(*kept)
        edges = edges.select { |_, e| kept.include?(e[:s]) && kept.include?(e[:t]) }
      end
      times = edges.values.map { |e| e[:at] } + nodes.values.map { |n| n[:at] }
      {
        nodes: nodes.values,
        edges: edges.values,
        meta: {
          context: context&.key || "root",
          records:  nodes.values.count { |n| n[:kind] == "record" },
          entities: nodes.values.count { |n| n[:kind] == "entity" },
          contexts: nodes.values.count { |n| n[:kind] == "context" },
          edge_count: edges.size,
          claims_considered: claims.size,
          time_range: [ times.min, times.max ],
          generated_at: Time.current.iso8601,
          warnings: warnings
        }
      }
    end

    def empty_atlas(context)
      { nodes: [], edges: [],
        meta: { context: context&.key || "root", records: 0, entities: 0, contexts: 0,
                edge_count: 0, claims_considered: 0, time_range: nil,
                generated_at: Time.current.iso8601, warnings: [] } }
    end
  end
end
