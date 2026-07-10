module Enliterator
  # The pulse monitor (v0.16) — trigger a heartbeat cycle from the browser and
  # watch it live. GLOBAL by design: the heartbeat works every lane across
  # every context in one budget; it deliberately ignores the nav's context
  # selector (which scopes Chat/Status/Settings/Requests).
  #
  # Everything the monitor shows is derived from existing provenance — the
  # open ledger row plus the visits it stamps as they happen. No new state.
  class HeartbeatController < ApplicationController
    # A visit row for every facet of one record may be minutes apart; the
    # monitor calls a cycle quiet (possibly crashed) after this much silence.
    STALL_AFTER = 5.minutes

    def index
      # v0.23: the page heals on view — orphaned rows (process died
      # mid-cycle) get their honest ending stamped before anything renders.
      Enliterator::Heartbeat.reap_orphans!

      # The blocking predicate IS the lock's predicate (unfinished AND inside
      # the overlap window). An open row OLDER than the window is crash
      # evidence — it renders in the recent table, not as a live monitor that
      # would trap this page in watching-nothing mode forever.
      @running = Enliterator::Heartbeat.unfinished
                   .where("started_at > ?", Enliterator::Heartbeat::OVERLAP_WINDOW.ago)
                   .order(:started_at).last
      @recent  = Enliterator::Heartbeat.order(started_at: :desc).limit(10).to_a
      # v0.20: PREPARED when any cycle has ever run — the last ledger row's
      # `planned` jsonb, with its as-of stamp. The live census runs only on a
      # host with NO preparation to read (first-run: the page must still show
      # what the first beat would do). open! re-plans authoritatively at beat.
      @plan =
        if @running
          nil
        elsif (last = @recent.first)
          Enliterator::Heartbeat::PreparedPlan.new(last)
        else
          Enliterator::Heartbeat.plan
        end
      @default_budget = Enliterator.configuration.heartbeat_budget_tokens
    end

    def beat
      row, plan = Enliterator::Heartbeat.open!(
        budget: sanitized_budget,
        force:  params[:force].present?
      )
      row.execute_async!(plan)
      notice = "Heartbeat ##{row.id} started — #{plan.items.size} item(s), " \
               "budget #{number_with_delimiter(row.budget_tokens)} tokens."
      # Make the down-clamp honest: when the ask exceeded the configured ceiling
      # the cycle silently ran at the ceiling (sanitized_budget). Say so, rather
      # than leave the raised number looking like it took effect.
      asked = params[:budget].to_i
      if asked > row.budget_tokens
        notice += " (Requested #{number_with_delimiter(asked)} — clamped to the " \
                  "configured ceiling of #{number_with_delimiter(row.budget_tokens)}.)"
      end
      flash[:notice] = notice
      redirect_to heartbeat_path
    rescue Enliterator::Heartbeat::Overlap => e
      flash[:alert] = e.message
      redirect_to heartbeat_path
    end

    # The monitor's poll — everything live derives from the row + its stamped
    # visits. Items done = DISTINCT (record, facet, context) tuples: escalation
    # stamps multiple visits per item and failed tends stamp rows too, so a
    # raw visit count would inflate progress.
    def pulse
      row = Enliterator::Heartbeat.find(params[:id])
      # v0.23: a watched monitor self-heals — the poll that finds its row
      # orphaned stamps it, and this same response carries the honest ending
      # (finished + error), so the JS resolves without anyone reloading.
      row.reap! if row.orphaned?
      visits = row.visits

      done_by_reason = visits.select(:tendable_type, :tendable_id, :facet, :context_id, :reason)
                             .distinct.group_by(&:reason).transform_values(&:size)
      last_visits = visits.includes(:context).order(created_at: :desc).limit(10).map do |v|
        {
          id: v.id, facet: v.facet, context_key: v.context&.key || "root",
          tendable: "#{v.tendable_type}/#{v.tendable_id}", tier: v.tier,
          confidence: v.confidence, status: v.status, applied: v.applied,
          reason: v.reason, tokens: v.tokens.is_a?(Hash) ? v.tokens["total"].to_i : 0,
          at: v.created_at.iso8601,
          # v0.23: pre-formatted in the APP zone — the browser's system zone
          # may differ (the launchd Central-vs-Pacific gotcha reached the
          # ticker: header 09:33, rows "11:41").
          at_label: v.created_at.strftime("%H:%M:%S")
        }
      end

      payload = {
        id: row.id, mode: row.mode, started_at: row.started_at.iso8601,
        finished: row.finished?, error: row.error,
        # v0.23: the actual phase + liveness — the monitor can say "running
        # audit…" and the stall banner fires in phases that produce no visits.
        phase: row.phase,
        pulse_at: row.pulse_at&.iso8601,
        planned_count: row.planned_count,
        planned_by_reason: row.planned.dig("counts") || {},
        done_by_reason: done_by_reason,
        items_done: done_by_reason.values.sum,
        tokens_total: visits.sum { |v| v.tokens.is_a?(Hash) ? v.tokens["total"].to_i : 0 },
        budget_tokens: row.budget_tokens,
        last_visit_at: visits.maximum(:created_at)&.iso8601,
        stalled: !row.finished? &&
                 (row.pulse_at || visits.maximum(:created_at) || row.started_at) < STALL_AFTER.ago,
        last_visits: last_visits
      }
      if row.finished?
        payload[:executed]   = row.executed
        payload[:warnings]   = row.warnings
        payload[:considerer] = row.considerer
      end
      render json: payload
    end

    private

    # Blank/garbage/zero → the config default; anything above the configured
    # budget clamps DOWN to it (a stray extra zero in the box must not
    # authorize a mega-cycle).
    def sanitized_budget
      default = Enliterator.configuration.heartbeat_budget_tokens.to_i
      asked   = params[:budget].to_i
      return default if asked < 1
      [ asked, default ].min
    end

    def number_with_delimiter(n)
      helpers.number_with_delimiter(n)
    end
  end
end
