module Enliterator
  class Heartbeat < ApplicationRecord
    # The event-driven scheduler's PURE READ half (v0.15). Computes a
    # prioritized, budget-bounded work queue from signals already in the
    # tables — no new state, no writes, no network.
    #
    # Budget ENVELOPES, not strict priority (the v0.14 verdict, made fair):
    #   change envelope (budget × heartbeat_change_share, default 20%)
    #     ordered source_change → neighborhood → vocabulary
    #     (correctness before deepening; vocabulary last — biggest waves, and
    #      the one trigger v0.14 did not measure)
    #   frontier (everything the change envelope doesn't use spills here —
    #     first attention is where claims/dollar is ~10×)
    #   sweep (stale_after, DEMOTED to a safety net — leftovers only)
    #
    # Every trigger is anchored to the lane's MAX(started_at) of succeeded
    # applied visits — NOT finished_at: text and vocabulary are read at visit
    # START, so a visit that finishes after a change must not mark the record
    # caught-up. Root lanes use explicit `context_id IS NULL` (the root rule;
    # Tendable#last_tended_at(context: nil) is UNFILTERED — a named trap this
    # planner deliberately avoids).
    class Planner
      REASONS              = %w[source_change neighborhood vocabulary frontier sweep].freeze
      FALLBACK_ITEM_TOKENS = 4_000
      TRAILING_WINDOW      = 50     # visits per facet for the cost estimate
      FAILURE_BACKOFF      = 24.hours

      # A unit of scheduling: (context, facet) — plus the host model for root
      # lanes, where candidates come from the host table rather than from
      # context memberships.
      Lane = Struct.new(:context, :facet, :model, keyword_init: true) do
        def label = "#{context&.key || 'root'}/#{facet}#{model ? " (#{model.name})" : ''}"
        def context_id = context&.id
      end

      def initialize(budget: nil)
        @config    = Enliterator.configuration
        @budget    = (budget || @config.heartbeat_budget_tokens).to_i
        @warnings  = []
        @est_cache = {}
        @seen      = Set.new   # [type, id, facet, context_id] — first reason wins
      end

      def plan
        items      = []
        change_cap = (@budget * @config.heartbeat_change_share.to_f).floor

        items.concat(collect_change(change_cap))
        change_used = items.sum(&:est_tokens)

        frontier_items, frontier_remaining = collect_frontier(@budget - change_used)
        items.concat(frontier_items)

        items.concat(collect_sweep(@budget - items.sum(&:est_tokens)))

        Plan.new(
          budget:             @budget,
          change_cap:         change_cap,
          items:              items,
          warnings:           @warnings,
          frontier_remaining: frontier_remaining,
          horizon_tokens:     horizon_tokens(frontier_remaining)
        )
      end

      private

      # ---- lanes -------------------------------------------------------------

      # Context lanes: every context × the facets it DECLARES ITSELF (rule 2:
      # declaration location = tending scope). A root Context row with no policy
      # block declares nothing and yields no lanes — root facets are root lanes.
      def context_lanes
        @context_lanes ||= Enliterator::Context.order(:id).flat_map do |ctx|
          Enliterator.staffing.facets_declared_in(ctx.key).map do |facet|
            Lane.new(context: ctx, facet: facet.to_s)
          end
        end
      end

      # Root lanes: root-declared facets × tendable models (candidates live in
      # the host tables). Falls back to config.tending_facets when no staffing
      # declares root facets — same fallback Settings uses.
      def root_lanes
        @root_lanes ||= begin
          facets = Enliterator.staffing.facets_declared_in(nil)
          facets = Array(@config.tending_facets).map(&:to_s) if facets.empty?
          facets.flat_map { |facet| tendable_models.map { |m| Lane.new(facet: facet.to_s, model: m) } }
        end
      end

      def all_lanes
        context_lanes + root_lanes
      end

      # Registry ∪ visit log (the registry only fills as classes autoload in
      # dev — the visit log is the truer authority, same as Settings).
      def tendable_models
        @tendable_models ||= begin
          names = Enliterator.tendable_models.map(&:name) |
                  Enliterator::Visit.distinct.pluck(:tendable_type).compact
          names.sort.filter_map do |name|
            name.constantize
          rescue NameError
            @warnings << "tendable type #{name} in the visit log no longer resolves — skipped"
            nil
          end
        end
      end

      # ---- the change envelope ----------------------------------------------

      def collect_change(cap)
        items = []
        remaining = cap
        { "source_change" => method(:source_change_candidates),
          "neighborhood"  => method(:neighborhood_candidates),
          "vocabulary"    => method(:vocabulary_candidates) }.each_value do |collector|
          break if remaining <= 0
          collected = collector.call(remaining)
          items.concat(collected)
          remaining -= collected.sum(&:est_tokens)
        end
        items
      end

      # 1. SOURCE CHANGE — the record's text moved under its claims (a
      # correctness trigger). Default test: host updated_at > lane last
      # started_at; hosts with touch chains/backfills override via
      # config.heartbeat_source_changed (per-record callable).
      def source_change_candidates(remaining)
        items = []
        all_lanes.each do |lane|
          break if remaining <= 0
          est = est_for(lane.facet)
          max = remaining / est
          next note_truncation("source_change", lane, est) if max <= 0

          collected =
            if @config.heartbeat_source_changed
              source_change_by_callable(lane, max)
            else
              source_change_by_sql(lane, max)
            end
          collected.each do |type, id|
            next unless claim_seen(type, id, lane)
            items << item(type, id, lane, "source_change", est)
            remaining -= est
          end
        end
        items
      end

      # Set-based default: per (lane, member type), join the lane's per-record
      # MAX(started_at) against the host table's updated_at.
      def source_change_by_sql(lane, max)
        member_models_for(lane).flat_map do |model|
          unless model.column_names.include?("updated_at")
            @warnings << "source_change: #{model.name} has no updated_at — lane #{lane.label} skipped " \
                         "(set config.heartbeat_source_changed to supply a test)"
            next []
          end
          pk = "t.#{model.connection.quote_column_name(model.primary_key)}"
          rows = select_rows(<<~SQL, lane.facet, model.name, max)
            SELECT lv.tendable_id
            FROM (
              SELECT tendable_id, MAX(started_at) AS last_started
              FROM enliterator_visits
              WHERE #{ctx_pred(lane)} AND facet = ? AND tendable_type = ?
                AND status = 'succeeded' AND applied
              GROUP BY tendable_id
            ) lv
            JOIN #{model.quoted_table_name} t ON CAST(#{pk} AS TEXT) = lv.tendable_id
            WHERE t.updated_at > lv.last_started
            ORDER BY lv.last_started ASC
            LIMIT ?
          SQL
          rows.map { |(id)| [ model.name, id ] }
        end
      end

      # Host-override path: load the lane's tended set and ask the callable per
      # record. Bounded by the lane's tended count; batched.
      def source_change_by_callable(lane, max)
        out = []
        member_models_for(lane).each do |model|
          last_by_id = select_rows(<<~SQL, lane.facet, model.name).to_h
            SELECT tendable_id, MAX(started_at)
            FROM enliterator_visits
            WHERE #{ctx_pred(lane)} AND facet = ? AND tendable_type = ?
              AND status = 'succeeded' AND applied
            GROUP BY tendable_id
          SQL
          model.where(model.primary_key => last_by_id.keys).find_each do |record|
            break if out.size >= max
            last = last_by_id[record.public_send(model.primary_key).to_s]
            out << [ model.name, record.public_send(model.primary_key).to_s ] if @config.heartbeat_source_changed.call(record, last)
          end
          break if out.size >= max
        end
        out.first(max)
      end

      # 2. NEIGHBORHOOD — context-mates were tended since this record's last
      # visit in the lane (v0.14's MEASURED deepening signal). Context lanes
      # ONLY: at root, neighbors are corpus-wide and any frontier work would
      # re-trigger everything forever. Two guards against the same failure
      # inside a context: suppressed while the lane's own frontier is non-empty
      # (finish reading the shelf first), and a per-record cooldown. One window
      # scan per lane — every visit after mine is necessarily another member's,
      # so `total - my_row_number` counts mates with no join (visits, not
      # distinct mates: a documented proxy).
      def neighborhood_candidates(remaining)
        items     = []
        threshold = @config.heartbeat_neighbor_threshold.to_i
        cooldown  = cooldown_cutoff
        context_lanes.each do |lane|
          break if remaining <= 0
          next unless lane_active?(lane)
          if frontier_count(lane).positive?
            @warnings << "neighborhood: #{lane.label} suppressed — frontier non-empty (first attention first)"
            next
          end
          est = est_for(lane.facet)
          max = remaining / est
          next note_truncation("neighborhood", lane, est) if max <= 0

          rows = select_rows(<<~SQL, lane.facet, threshold, cooldown, max)
            WITH lane AS (
              SELECT tendable_type, tendable_id, created_at,
                     ROW_NUMBER() OVER (ORDER BY created_at, id) AS rn,
                     COUNT(*) OVER () AS total
              FROM enliterator_visits
              WHERE #{ctx_pred(lane)} AND facet = ? AND status = 'succeeded' AND applied
            )
            SELECT tendable_type, tendable_id
            FROM lane
            GROUP BY tendable_type, tendable_id
            HAVING MAX(total) - MAX(rn) >= ? AND MAX(created_at) < ?
            ORDER BY MAX(rn) ASC
            LIMIT ?
          SQL
          rows.each do |type, id|
            next unless claim_seen(type, id, lane)
            items << item(type, id, lane, "neighborhood", est)
            remaining -= est
          end
        end
        items
      end

      # 3. VOCABULARY — an approved term joined the lane's effective contract
      # after this record was last read there. The lane's vocabulary version V
      # = MAX(updated_at) over approved suggestions visible from the lane
      # (read-up, exactly Vocabulary.for's scope). Oldest-tended first — a
      # resumable cursor with zero new state: one re-tend catches a record up
      # to ALL approvals at once, so budget-cut waves drain across cycles.
      def vocabulary_candidates(remaining)
        unless @config.apply_approved_keys
          @warnings << "vocabulary trigger skipped — apply_approved_keys is false (approvals don't change the effective contract)"
          return []
        end
        items = []
        all_lanes.each do |lane|
          break if remaining <= 0
          v = vocabulary_version(lane)
          next unless v
          est = est_for(lane.facet)
          max = remaining / est
          next note_truncation("vocabulary", lane, est) if max <= 0

          wave = select_value(<<~SQL, lane.facet, v).to_i
            SELECT COUNT(*) FROM (
              SELECT tendable_type, tendable_id
              FROM enliterator_visits
              WHERE #{ctx_pred(lane)} AND facet = ? AND status = 'succeeded' AND applied
              GROUP BY tendable_type, tendable_id
              HAVING MAX(started_at) < ?
            ) sub
          SQL
          next if wave.zero?

          rows = select_rows(<<~SQL, lane.facet, v, max)
            SELECT tendable_type, tendable_id
            FROM enliterator_visits
            WHERE #{ctx_pred(lane)} AND facet = ? AND status = 'succeeded' AND applied
            GROUP BY tendable_type, tendable_id
            HAVING MAX(started_at) < ?
            ORDER BY MAX(started_at) ASC
            LIMIT ?
          SQL
          taken = 0
          rows.each do |type, id|
            next unless claim_seen(type, id, lane)
            items << item(type, id, lane, "vocabulary", est)
            remaining -= est
            taken += 1
          end
          if wave > taken
            cycles = (((wave - taken) * est) / [ @budget * @config.heartbeat_change_share.to_f, 1 ].max).ceil
            @warnings << "vocabulary: #{lane.label} wave has #{wave - taken} record(s) remaining ≈ #{cycles} cycle(s) at the current change share"
          end
        end
        items
      end

      # The lane's effective-vocabulary clock. Suggestion.updated_at is stamped
      # by approve_key!; per-row edits of an approved row can re-advance it —
      # an accepted approximation (re-tends are NOOP-safe per v0.14).
      def vocabulary_version(lane)
        scope = lane.context ? lane.context.scope_ids : nil
        Enliterator::Suggestion.where(status: "approved", facet: lane.facet, context_id: scope)
                               .maximum(:updated_at)
      end

      # ---- frontier -----------------------------------------------------------

      # The bulk of every cycle while anything remains unread: members never
      # tended in their lane. Per-lane quotas + ONE redistribution pass —
      # deterministic fairness, so 35K CRS reports can't starve an 82-member
      # context. Returns [items, {lane_label => remaining_count}].
      def collect_frontier(envelope)
        lanes = all_lanes
        remaining_counts = lanes.each_with_object({}) { |lane, h| h[lane.label] = frontier_count(lane) }
        return [ [], remaining_counts ] if envelope <= 0 || lanes.empty?

        items = []
        spent = 0
        more  = {}   # lane => items fetched in pass 1 (the OFFSET for pass 2)
        quota = envelope / lanes.size

        lanes.each do |lane|
          next if remaining_counts[lane.label].zero?
          est = est_for(lane.facet)
          max = quota / est
          next note_truncation("frontier", lane, est) if max <= 0
          fetched = frontier_fetch(lane, limit: max)
          fetched.each { |type, id| items << item(type, id, lane, "frontier", est) }
          spent += fetched.size * est
          more[lane] = fetched.size if remaining_counts[lane.label] > fetched.size
        end

        # Redistribute what underfilled lanes left to the lanes with more shelf.
        leftover = envelope - spent
        if leftover.positive? && more.any?
          share = leftover / more.size
          more.each do |lane, offset|
            est = est_for(lane.facet)
            max = share / est
            next if max <= 0
            frontier_fetch(lane, limit: max, offset: offset).each do |type, id|
              items << item(type, id, lane, "frontier", est)
            end
          end
        end

        # Tiny-budget guard: when per-lane quotas rounded every lane to zero but
        # the envelope can still afford items, fill greedily in lane order —
        # a 30K-token supervised run must not plan an empty cycle.
        if items.empty?
          remaining = envelope
          lanes.each do |lane|
            break if remaining <= 0
            next if remaining_counts[lane.label].zero?
            est = est_for(lane.facet)
            max = remaining / est
            next if max <= 0
            frontier_fetch(lane, limit: max).each do |type, id|
              items << item(type, id, lane, "frontier", est)
              remaining -= est
            end
          end
        end
        [ items, remaining_counts ]
      end

      # Anti-join: members/rows with NO succeeded applied visit in the lane,
      # minus records in failure backoff. Never the in-memory done-set
      # (tend_context) or the NOT IN id-array (enliterator:tend) — wrong at 35K.
      def frontier_fetch(lane, limit:, offset: 0)
        if lane.model
          pk   = "t.#{lane.model.connection.quote_column_name(lane.model.primary_key)}"
          type = ActiveRecord::Base.connection.quote(lane.model.name)
          select_rows(<<~SQL, lane.facet, lane.facet, FAILURE_BACKOFF.ago, limit, offset)
            SELECT CAST(#{pk} AS TEXT)
            FROM #{lane.model.quoted_table_name} t
            LEFT JOIN enliterator_visits v
              ON v.tendable_type = #{type} AND v.tendable_id = CAST(#{pk} AS TEXT)
             AND v.context_id IS NULL AND v.facet = ? AND v.status = 'succeeded' AND v.applied
            WHERE v.id IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM enliterator_visits f
                WHERE f.tendable_type = #{type} AND f.tendable_id = CAST(#{pk} AS TEXT)
                  AND f.context_id IS NULL AND f.facet = ?
                  AND f.status = 'failed' AND f.created_at > ?)
            ORDER BY #{pk}
            LIMIT ? OFFSET ?
          SQL
            .map { |(id)| [ lane.model.name, id ] }
        else
          select_rows(<<~SQL, lane.context_id, lane.facet, lane.context_id, lane.context_id, lane.facet, FAILURE_BACKOFF.ago, limit, offset)
            SELECT m.member_type, m.member_id
            FROM enliterator_context_memberships m
            LEFT JOIN enliterator_visits v
              ON v.tendable_type = m.member_type AND v.tendable_id = m.member_id
             AND v.context_id = ? AND v.facet = ? AND v.status = 'succeeded' AND v.applied
            WHERE m.context_id = ? AND v.id IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM enliterator_visits f
                WHERE f.tendable_type = m.member_type AND f.tendable_id = m.member_id
                  AND f.context_id = ? AND f.facet = ?
                  AND f.status = 'failed' AND f.created_at > ?)
            ORDER BY m.created_at, m.id
            LIMIT ? OFFSET ?
          SQL
        end
      end

      def frontier_count(lane)
        @frontier_counts ||= {}
        @frontier_counts[lane.label] ||=
          if lane.model
            pk   = "t.#{lane.model.connection.quote_column_name(lane.model.primary_key)}"
            type = ActiveRecord::Base.connection.quote(lane.model.name)
            select_value(<<~SQL, lane.facet).to_i
              SELECT COUNT(*)
              FROM #{lane.model.quoted_table_name} t
              LEFT JOIN enliterator_visits v
                ON v.tendable_type = #{type} AND v.tendable_id = CAST(#{pk} AS TEXT)
               AND v.context_id IS NULL AND v.facet = ? AND v.status = 'succeeded' AND v.applied
              WHERE v.id IS NULL
            SQL
          else
            select_value(<<~SQL, lane.context_id, lane.facet, lane.context_id).to_i
              SELECT COUNT(*)
              FROM enliterator_context_memberships m
              LEFT JOIN enliterator_visits v
                ON v.tendable_type = m.member_type AND v.tendable_id = m.member_id
               AND v.context_id = ? AND v.facet = ? AND v.status = 'succeeded' AND v.applied
              WHERE m.context_id = ? AND v.id IS NULL
            SQL
          end
      end

      # ---- the safety-net sweep -----------------------------------------------

      # stale_after, DEMOTED: only what the frontier leaves. Oldest first.
      def collect_sweep(remaining)
        items  = []
        cutoff = Time.current - @config.stale_after
        all_lanes.each do |lane|
          break if remaining <= 0
          est = est_for(lane.facet)
          max = remaining / est
          next note_truncation("sweep", lane, est) if max <= 0

          rows = select_rows(<<~SQL, lane.facet, cutoff, max)
            SELECT tendable_type, tendable_id
            FROM enliterator_visits
            WHERE #{ctx_pred(lane)} AND facet = ? AND status = 'succeeded' AND applied
            GROUP BY tendable_type, tendable_id
            HAVING MAX(started_at) < ?
            ORDER BY MAX(started_at) ASC
            LIMIT ?
          SQL
          rows.each do |type, id|
            next unless claim_seen(type, id, lane)
            items << item(type, id, lane, "sweep", est)
            remaining -= est
          end
        end
        items
      end

      # ---- cost estimation ------------------------------------------------------

      # Tokens per ITEM, not per visit: sum of ALL succeeded visit tokens on the
      # facet over the trailing window ÷ APPLIED visits — escalation chains
      # (junior applied:false rows) price themselves in via the ratio. Fallbacks
      # logged: global mean, then the engine constant.
      def est_for(facet)
        @est_cache[facet] ||= begin
          est = token_ratio(Enliterator::Visit.where(facet: facet))
          if est.nil?
            est = global_est
            @warnings << "facet #{facet}: no token history — estimating #{est} tokens/item " \
                         "(#{est == FALLBACK_ITEM_TOKENS ? 'engine default' : 'global trailing mean'})"
          end
          est
        end
      end

      def global_est
        @global_est ||= token_ratio(Enliterator::Visit.all) || FALLBACK_ITEM_TOKENS
      end

      def token_ratio(scope)
        rows = scope.where(status: "succeeded")
                    .order(created_at: :desc).limit(TRAILING_WINDOW)
                    .pluck(:tokens, :applied)
        applied = rows.count { |_, a| a }
        return nil if applied.zero?
        total = rows.sum { |t, _| t.is_a?(Hash) ? (t["total"] || t[:total]).to_i : 0 }
        return nil if total.zero?   # token-less history (stubs) — never estimate 0
        [ total / applied, 1 ].max
      end

      # ---- shared helpers --------------------------------------------------------

      def item(type, id, lane, reason, est)
        Plan::Item.new(tendable_type: type, tendable_id: id.to_s, facet: lane.facet,
                       context: lane.context, reason: reason, est_tokens: est)
      end

      # First reason wins; a record never appears twice for the same lane.
      def claim_seen(type, id, lane)
        @seen.add?([ type, id.to_s, lane.facet, lane.context_id ])
      end

      def note_truncation(reason, lane, est)
        @warnings << "#{reason}: #{lane.label} truncated — under #{est} tokens of envelope left"
        nil
      end

      # Quiet-lane pre-gate (neighborhood only): no lane visits since the last
      # finished beat ⇒ nothing can have crossed the threshold since.
      def lane_active?(lane)
        since = last_finished_beat_started_at
        return true unless since
        Enliterator::Visit.where(context_id: lane.context_id, facet: lane.facet)
                          .where("created_at > ?", since).exists?
      end

      def last_finished_beat_started_at
        return @last_beat if defined?(@last_beat)
        @last_beat = Enliterator::Heartbeat.where.not(finished_at: nil).maximum(:started_at)
      end

      def cooldown_cutoff
        Time.current - [ @config.stale_after / 10, 1.day ].max
      end

      # The ONE structural variant in the grouped-visit queries: NULL is the
      # root scope (root rule). Inlined — the lane's context_id is an integer
      # from our own table (sanitized anyway for hygiene).
      def ctx_pred(lane)
        if lane.context_id
          ActiveRecord::Base.sanitize_sql_array([ "context_id = ?", lane.context_id ])
        else
          "context_id IS NULL"
        end
      end

      def member_models_for(lane)
        return [ lane.model ] if lane.model
        Enliterator::ContextMembership.where(context_id: lane.context_id)
                                      .distinct.pluck(:member_type)
                                      .filter_map do |name|
          name.constantize
        rescue NameError
          @warnings << "member type #{name} in #{lane.label} no longer resolves — skipped"
          nil
        end
      end

      def horizon_tokens(frontier_remaining)
        lanes_by_label = all_lanes.index_by(&:label)
        frontier_remaining.sum do |label, count|
          lane = lanes_by_label[label]
          count * (lane ? est_for(lane.facet) : global_est)
        end
      end

      def select_rows(sql, *binds)
        ActiveRecord::Base.connection.select_rows(
          ActiveRecord::Base.sanitize_sql_array([ sql, *binds ])
        )
      end

      def select_value(sql, *binds)
        ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array([ sql, *binds ])
        )
      end
    end
  end
end
