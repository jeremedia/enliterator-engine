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

    # Keys whose values IDENTIFY their record (control numbers, in the
    # cataloger's sense). Only these — plus record titles — feed the
    # resolution index; an attribute claim (advisor, thematic_cluster) must
    # never self-resolve into silence.
    IDENTIFIER_KEY_RX = /(^|_)(number|no|id|code|doi|isbn|issn|identifier)(_|$)/

    def build(context: nil, node_cap: nil)
      cap = node_cap || Enliterator.configuration.atlas_node_cap
      key = [ "enliterator/atlas", context&.key || "root", cap,
              "hb#{Enliterator::Heartbeat.maximum(:id) || 0}" ].join("/")
      Rails.cache.fetch(key, expires_in: TTL) { assemble(context: context, node_cap: cap) }
    end

    # The uncached computation. Returns { nodes:, edges:, meta: }.
    def assemble(context: nil, node_cap: nil)
      cap    = node_cap || Enliterator.configuration.atlas_node_cap
      claims = understanding_claims(context).to_a
      return empty_atlas(context) if claims.empty?

      by_record = claims.group_by { |c| [ c.tendable_type, c.tendable_id ] }
      records   = materialize(by_record.keys)
      verdicts  = audit_verdicts(claims)

      nodes  = {}   # id => node hash
      edges  = {}   # [s, t, key] => edge hash (deduped; weight = max confidence)
      index  = resolution_index(claims, by_record, records)

      # Record nodes (label, genre group, first-claim timestamp, drill-down path).
      by_record.each do |(type, id), cs|
        rec  = records[[ type, id ]]
        ctx  = dominant_context(cs)
        nodes[record_node_id(type, id)] = {
          id: record_node_id(type, id), kind: "record",
          label: record_label(rec, type, id),
          group: ctx&.key || "root",
          size: cs.size,
          at: cs.map(&:created_at).min.to_i,
          path: "status/#{type}/#{id}"
        }
      end

      # Context diamonds + membership edges (the layout's gravity wells).
      by_record.each do |(type, id), cs|
        ctx = dominant_context(cs)
        next unless ctx
        cid = "c:#{ctx.key}"
        nodes[cid] ||= { id: cid, kind: "context", label: ctx.name || ctx.key,
                         group: ctx.key, size: 0, at: cs.map(&:created_at).min.to_i }
        nodes[cid][:size] += 1
        ekey = [ record_node_id(type, id), cid, "in-context" ]
        edges[ekey] ||= { s: ekey[0], t: cid, key: "in-context", w: 0.2,
                          at: cs.map(&:created_at).min.to_i }
      end

      # Typed edges from entity-bearing claims.
      bearing = entity_bearing_keys(claims)
      claims.each do |c|
        next unless bearing.include?(c.key)
        source = record_node_id(c.tendable_type, c.tendable_id)
        extract_terms(c.value).each do |term|
          norm   = term.downcase.strip
          target = index[norm]
          next if target == source                       # identity self-reference
          unless target
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

      apply_cap(nodes, edges, cap, claims, context)
    end

    # ---- claim scope -----------------------------------------------------

    # Live claims that ARE understanding (Claim.understanding — extracted to
    # the model in v0.24 so the Catalog reads the same definition), read
    # cumulatively up the context path.
    def understanding_claims(context)
      scope = Enliterator::Claim.live.understanding
      scope = scope.where(context_id: context.scope_ids) if context
      scope
    end

    # ---- resolution ------------------------------------------------------

    # {normalized short string => record node id}, UNIQUE values only — a
    # collision means the string can't name one record, so it stays an entity.
    # Sources: IDENTIFIER claim values (eo_number "13129") + record titles.
    def resolution_index(claims, by_record, records)
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
        add.call(c.value, record_node_id(c.tendable_type, c.tendable_id))
      end
      by_record.each_key do |(type, id)|
        title = record_label(records[[ type, id ]], type, id)
        add.call(title, record_node_id(type, id))
      end
      index
    end

    # ---- entity extraction -----------------------------------------------

    # A key contributes edges when the MEDIAN of its extracted terms is short
    # — prose keys (summary, key_findings) fall out without a denylist.
    def entity_bearing_keys(claims)
      lengths = Hash.new { |h, k| h[k] = [] }
      claims.each { |c| extract_terms(c.value).each { |t| lengths[c.key] << t.length } }
      lengths.select { |_, ls| ls.any? && median(ls) <= SHORT }.keys.to_set
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

    def record_node_id(type, id) = "r:#{type}:#{id}"

    def record_label(rec, type, id)
      rec&.try(:title).presence || rec&.try(:name).presence || "#{type} ##{id}"
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

    # Latest audit verdict per claim, human outranking examiner (the anchor
    # is the only independent ground truth — same precedence as Audit.accuracy).
    def audit_verdicts(claims)
      Enliterator::Audit.where(claim_id: claims.map(&:id)).order(:created_at)
                        .each_with_object({}) do |a, h|
        next if h[a.claim_id]&.start_with?("human:") && a.source == "examiner"
        h[a.claim_id] = "#{a.source}:#{a.verdict}"
      end
    end

    # Over the cap: keep the most-connected nodes and say so. Edges touching
    # a dropped node are dropped with it.
    def apply_cap(nodes, edges, cap, claims, context)
      warnings = []
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
