module Enliterator
  # v0.24: the CATALOG — browse and search the enliterated holdings.
  #
  # Every other surface is curatorial back-office or a single keyhole (Chat
  # retrieves a handful of records; /status/:type/:id shows one). The catalog
  # is the OPAC over the collection: search by meaning through the same
  # embedding pool Chat retrieval reads, browse by SUBJECT HEADING (the
  # claim keys and values actually in use — the controlled vocabulary as a
  # browse index), and see the understanding on every card — accumulated
  # claims, tending depth, provenance. The compounding, made visible.
  #
  # Two spines, deliberately:
  # - The GRID and SEARCH walk the embedding spine (kind "primary" — one row
  #   per enliterated record, the exact pool Conversation retrieves from, so
  #   browse counts and search reach agree with Chat).
  # - SUBJECT browse walks the claim store directly: heading counts and
  #   click-through results are computed from the SAME scope with the SAME
  #   strict term rules, so every offered heading's count equals its result
  #   total. Headings are byte-exact stored values — the filter predicate is
  #   jsonb containment (value @> to_jsonb(term)), which matches a scalar
  #   string and an array element but never a hash or number; term extraction
  #   admits exactly those shapes and nothing else. (The Atlas extracts more
  #   generously for the graph — designation strings inside hashes — but a
  #   heading the filter can't find again would be a lie.)
  class Catalog
    PER_PAGE           = 24          # grid window
    SEARCH_K           = 24          # ANN top-K; search is one honest page, no pager
    HEADING_KEYS_CAP   = 8           # subject-heading keys shown
    HEADING_VALUES_CAP = 10          # top values per key
    HEADING_SAMPLE     = 40          # per-key sample for the heading-bearing test
    HEADING_SCAN_CAP   = 50_000      # per-key tally bound; counts render "≥" beyond it
    RECENT_CAP         = 8           # recently-tended strip
    EXCERPT_CHARS      = 220
    EXCERPT_KEY_RX     = /summary|abstract|description|overview/i
    SHORT              = Enliterator::Atlas::SHORT   # one definition of "short"
    TTL                = 5.minutes   # the v0.20 rollup idiom

    def initialize(context: nil, type: nil, embedder: Enliterator.embedder)
      @context  = context
      @type     = type      # pre-validated by the controller against tendable_models
      @embedder = embedder
    end

    # The cached landing blob (v0.20 idiom: heartbeat-keyed + short TTL —
    # republishes when a cycle lands, never goes stale-forever). Type-agnostic:
    # per-type counts live inside it; only the grid is type-filtered.
    def overview
      key = [ "enliterator/catalog", @context&.key || "root",
              "hb#{Enliterator::Heartbeat.maximum(:id) || 0}" ].join("/")
      Rails.cache.fetch(key, expires_in: TTL) { assemble_overview }
    end

    # One grid window in ACCESSION ORDER (newest embeddings first) — stable,
    # index-backed, and honest at any corpus size; ordering the whole spine by
    # last-visit would be a per-view census. Page clamps into 1..pages against
    # the cached total; a clamped page that still hydrates empty means the
    # collection moved under the cache — the view renders that honestly.
    def page(n)
      total = @type ? overview[:types][@type].to_i : overview[:stats][:enliterated]
      pages = [ (total.to_f / PER_PAGE).ceil, 1 ].max
      page  = n.to_i.clamp(1, pages)
      rows  = pool.order(id: :desc).offset((page - 1) * PER_PAGE).limit(PER_PAGE)
                  .pluck(:embeddable_type, :embeddable_id)   # never load vectors for browse
      { records: hydrate(rows), page: page, pages: pages, total: total }
    end

    # Search by meaning: embed the query, take the SEARCH_K nearest from the
    # pool. Degraded states are named, never faked — the Null embedder's
    # pseudo-vectors would RANK against real ones and look like results.
    def search(q)
      return { records: [], degraded: "null-embedder" } if null_embedder_degraded?
      vector = @embedder.embed(q)
      return { records: [], degraded: "no-vector" } if vector.nil?

      rows = pool.nearest_neighbors(:embedding, vector, distance: "cosine").first(SEARCH_K)
      pairs     = rows.map { |e| [ e.embeddable_type, e.embeddable_id.to_s ] }
      distances = rows.each_with_object({}) do |e, h|
        h[[ e.embeddable_type, e.embeddable_id.to_s ]] = e.neighbor_distance
      end
      { records: hydrate(pairs, distances: distances), degraded: nil }
    end

    # Records holding a live understanding claim key=value — the heading's
    # click-through. Same scope and same containment shapes as the heading
    # tally, so the count on the chip equals the total here.
    def subject(key, value, page: 1)
      scope = heading_scope(key)
      # v0.45: for a name key, the heading shows the CANONICAL form — expand it to
      # all its variant spellings so the click-through finds every record (the
      # congruence with the tally is preserved). Non-name keys are unchanged.
      scope =
        if name_key?(key)
          variants = Enliterator::NameAuthority.variants_for(value, context: @context)
          clause   = Array(variants).map { "enliterator_claims.value @> to_jsonb(?::text)" }.join(" OR ")
          scope.where(clause, *variants)
        else
          scope.where("enliterator_claims.value @> to_jsonb(?::text)", value)
        end
      matches = scope.distinct.order(:tendable_type, :tendable_id)
                     .pluck(:tendable_type, :tendable_id)
      total  = matches.size
      pages  = [ (total.to_f / PER_PAGE).ceil, 1 ].max
      pg     = page.to_i.clamp(1, pages)
      window = matches[(pg - 1) * PER_PAGE, PER_PAGE] || []
      { records: hydrate(window), page: pg, pages: pages, total: total,
        key: key, value: value }
    end

    # The open-stacks gesture: one random record from the pool (honoring any
    # type filter). Returns [type, id] or nil when nothing is enliterated.
    def wander
      total = pool.count
      return nil if total.zero?
      row = pool.offset(rand(total)).limit(1).pluck(:embeddable_type, :embeddable_id).first
      row && [ row[0], row[1].to_s ]
    end

    private

    # ---- spines ------------------------------------------------------------

    # The embedding spine: one "primary" row per enliterated record, membership-
    # filtered within a context (Embedding.in_context — Chat retrieval's pool).
    def base_pool
      Enliterator::Embedding.where(kind: "primary").in_context(@context)
    end

    def pool
      @type ? base_pool.where(embeddable_type: @type) : base_pool
    end

    # The claim-store spine for headings and stats: live UNDERSTANDING claims
    # (Claim.understanding — condition flags and host seeds are not knowledge),
    # read cumulatively up the context path AND intersected with membership —
    # without the membership predicate, a non-member's root claim would leak
    # into a scoped subject browse (claims read cumulatively; records don't).
    def scoped_understanding
      s = Enliterator::Claim.live.understanding
      if @context
        s = s.where(context_id: @context.scope_ids)
             .where(
               Enliterator::ContextMembership.member_exists(
                 @context,
                 type_sql: "enliterator_claims.tendable_type",
                 id_sql:   "enliterator_claims.tendable_id"
               ).arel.exists
             )
      end
      s
    end

    def heading_scope(key)
      scoped_understanding.where(key: key)
    end

    # v0.45 name authority: is this a key whose values are person names under
    # authority control? Empty config ⇒ always false ⇒ byte-identical.
    def name_key?(key)
      Enliterator.configuration.name_authority_keys.map(&:to_s).include?(key.to_s)
    end

    # The { value => canonical } resolution map for this context, loaded once.
    # Empty (no query) when no name keys are configured ⇒ byte-identical.
    def authority_map
      @authority_map ||=
        if Enliterator.configuration.name_authority_keys.present?
          Enliterator::NameAuthority.map_for(context: @context)
        else
          {}
        end
    end

    # ---- the cached overview -----------------------------------------------

    def assemble_overview
      {
        stats: {
          enliterated:     base_pool.count,
          corpus:          known_tendables.sum(&:count),
          live_claims:     scoped_understanding.count,
          vocabulary_keys: scoped_understanding.distinct.count(:key)
        },
        types:        base_pool.group(:embeddable_type).count,
        headings:     headings,
        recent:       recently_tended,
        generated_at: Time.current
      }
    end

    # The subject-heading browse index: for each heading-bearing key, the top
    # values by DISTINCT RECORD count (a record holding the same key/value at
    # root and in a context is one record, not two). Identifier keys are
    # excluded by NAME (Atlas::IDENTIFIER_KEY_RX — control numbers are access
    # points, not subject headings; the cataloger's distinction). Charter keys
    # (v0.57) are likewise excluded by NAME — the told identity is human-
    # attributed prose that would seed count-1 junk headings in a young browse
    # index. A SIBLING constant, deliberately NOT folded into IDENTIFIER_KEY_RX
    # (that constant is shared with the Atlas's authority classification, and
    # charter prose is neither an access point nor a control number).
    # Browse-index-only: an explicit subject_search by a charter key resolves.
    CHARTER_KEY_RX = /\Acharter_/

    def headings
      keys = scoped_understanding.distinct.pluck(:key)
      keys.reject { |k| k.match?(Enliterator::Atlas::IDENTIFIER_KEY_RX) || k.match?(CHARTER_KEY_RX) }
          .filter_map { |k| heading_for(k) }
          .sort_by { |h| -h[:records] }
          .first(HEADING_KEYS_CAP)
    end

    def heading_for(key)
      sample = heading_scope(key).limit(HEADING_SAMPLE).pluck(:value)
      return nil if sample.flat_map { |v| heading_terms(v) }.empty?   # prose/hash keys fall out

      rows   = heading_scope(key).limit(HEADING_SCAN_CAP)
                                 .pluck(:tendable_type, :tendable_id, :value)
      approx = rows.size >= HEADING_SCAN_CAP
      tally   = {}
      resolve = name_key?(key) # v0.45: group variant spellings under the canonical name
      rows.each do |(t, id, v)|
        heading_terms(v).each do |term|
          canon = resolve ? (authority_map[term] || term) : term
          (tally[canon] ||= Set.new) << [ t, id ]
        end
      end
      values = tally.map { |term, set| [ term, set.size ] }
                    .sort_by { |(term, n)| [ -n, term ] }
                    .first(HEADING_VALUES_CAP)
      return nil if values.empty?
      # More values than we'd show and not one of them groups records →
      # identifier-shaped in practice, no browse value. (Self-scaling: a tiny
      # collection's legitimately-unique headings still show.)
      return nil if values.first[1] <= 1 && tally.size > HEADING_VALUES_CAP

      { key: key, approx: approx, values: values,
        records: rows.map { |r| [ r[0], r[1] ] }.uniq.size }
    end

    # STRICT and BYTE-EXACT — exactly the shapes jsonb containment with a text
    # scalar can find again (string scalar, string array element). No
    # stripping, no hash digging, no numbers: a heading we can't filter by is
    # a lie. (Spec-pinned congruence with #subject.)
    def heading_terms(value)
      case value
      when String then (value.blank? || value.length > SHORT) ? [] : [ value ]
      when Array  then value.select { |e| e.is_a?(String) && !e.blank? && e.length <= SHORT }
      else []
      end
    end

    # The latest RECORDS tended (not the latest visits — escalation stamps
    # several visits per item, so dedupe to records), membership-scoped.
    def recently_tended
      v = Enliterator::Visit.where(status: "succeeded", applied: true)
      if @context
        v = v.where(context_id: @context.scope_ids)
             .where(
               Enliterator::ContextMembership.member_exists(
                 @context,
                 type_sql: "enliterator_visits.tendable_type",
                 id_sql:   "enliterator_visits.tendable_id"
               ).arel.exists
             )
      end
      rows = v.order(created_at: :desc).limit(RECENT_CAP * 5)
              .pluck(:tendable_type, :tendable_id, :created_at)
      recent = []
      rows.each do |(t, id, at)|
        next if recent.any? { |r| r[:type] == t && r[:id] == id.to_s }
        recent << { type: t, id: id.to_s, at: at }
        break if recent.size >= RECENT_CAP
      end
      recs = materialize(recent.map { |r| [ r[:type], r[:id] ] })
      recent.each { |r| r[:label] = label_for(recs[[ r[:type], r[:id] ]], r[:type], r[:id]) }
      recent
    end

    # ---- hydration -----------------------------------------------------------

    # [type, id] pairs (order preserved) -> card hashes. Bounded: per type on
    # the page, one record query + ONE claims query + ONE visit rollup + one
    # membership query — never per-card. A pair whose host record has vanished
    # (stale embedding) drops out rather than rendering a ghost.
    def hydrate(pairs, distances: {})
      pairs = pairs.map { |(t, id)| [ t, id.to_s ] }
      return [] if pairs.empty?

      recs      = materialize(pairs)
      claims_by = Hash.new { |h, k| h[k] = [] }
      visits_by = {}
      ctx_by    = Hash.new { |h, k| h[k] = [] }

      pairs.group_by(&:first).each do |type, typed|
        ids = typed.map(&:last)

        cs = Enliterator::Claim.live.understanding
                               .where(tendable_type: type, tendable_id: ids)
        cs = cs.where(context_id: @context.scope_ids) if @context
        cs.each { |c| claims_by[[ type, c.tendable_id ]] << c }

        Enliterator::Visit
          .where(tendable_type: type, tendable_id: ids, status: "succeeded", applied: true)
          .group(:tendable_id)
          .pluck(Arel.sql("tendable_id, COUNT(*), MAX(created_at)"))
          .each { |(id, n, at)| visits_by[[ type, id ]] = [ n, at ] }

        Enliterator::ContextMembership
          .where(member_type: type, member_id: ids).includes(:context)
          .each { |m| ctx_by[[ type, m.member_id ]] << (m.context.name || m.context.key) }
      end

      pairs.filter_map do |(type, id)|
        rec = recs[[ type, id ]]
        next if rec.nil?
        claims = claims_by[[ type, id ]]
        visits = visits_by[[ type, id ]]
        {
          type: type, id: id,
          label:         label_for(rec, type, id),
          excerpt:       excerpt_for(rec, claims),
          claim_count:   claims.size,
          visit_count:   visits ? visits[0] : 0,
          last_visit_at: visits && visits[1],
          contexts:      ctx_by[[ type, id ]].sort,
          distance:      distances[[ type, id ]]
        }
      end
    end

    # What the collection UNDERSTANDS about the record, briefly: a summary-like
    # claim wins, else the longest prose claim, else the record's own text
    # (Conversation#snippet_for's pattern) — claims first, source last.
    def excerpt_for(rec, claims)
      strs = claims.select { |c| c.value.is_a?(String) && c.value.present? }
      pick = strs.find { |c| c.key.match?(EXCERPT_KEY_RX) } ||
             strs.max_by { |c| c.value.length }
      text = pick&.value
      text = source_text(rec) if text.blank?
      text = text.to_s.gsub(/\s+/, " ").strip
      text.length > EXCERPT_CHARS ? "#{text[0, EXCERPT_CHARS]}…" : text
    end

    def source_text(rec)
      return "" unless rec.respond_to?(:enliterator_text)
      rec.enliterator_text.to_s
    rescue StandardError
      ""
    end

    def label_for(rec, type, id)
      rec&.try(:title).presence || rec&.try(:name).presence || "#{type} ##{id}"
    end

    # [[type, id], ...] -> { [type, id(String)] => record } (Atlas's pattern).
    def materialize(pairs)
      pairs.group_by(&:first).each_with_object({}) do |(type, typed), h|
        klass = type.to_s.safe_constantize
        next unless klass
        klass.where(klass.primary_key => typed.map(&:last)).each do |rec|
          h[[ type, rec[klass.primary_key].to_s ]] = rec
        end
      end
    end

    # Registry ∪ visit log — the same authority rule as the planner, Condition,
    # and Settings: in dev the registry only fills as classes autoload, so a
    # fresh boot's first catalog view would count a corpus of zero (and CACHE
    # it — the v0.20 idiom would serve the lie for five minutes). v0.25: host
    # types only — tended Parts must not inflate the corpus.
    def known_tendables
      # Mask synthesized types (composite-work wholes) — they are not corpus
      # documents; this keeps the corpus COUNT honest. (The book stays drillable
      # via tendable_type?, and its claims still power the subject browse.)
      names = Enliterator.mask_synthesized(
        Enliterator.tendable_models.map(&:name) |
        Enliterator::Visit.host_tendable_types
      )
      names.sort.filter_map { |n| n.safe_constantize }
    end

    # Mirrors Conversation#null_degraded: the Null embedder is fine in specs
    # (allow_null_llm), a silent lie in production — its deterministic
    # pseudo-vector would rank against real embeddings and look like a result.
    def null_embedder_degraded?
      return false unless @embedder.is_a?(Enliterator::Adapters::Embedder::Null)
      return false if Enliterator.configuration.allow_null_llm
      Enliterator.logger&.warn(
        "[enliterator] catalog search resolved the Null embedder (no gateway key); " \
        "showing the browse instead. Set ENLITERATOR_LLM_KEY to search by meaning."
      )
      true
    end
  end
end
