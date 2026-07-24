# frozen_string_literal: true

module Enliterator
  class Heartbeat < ApplicationRecord
    # v-next: the DIRECTED PULSE resolver — turns a definable target set into a
    # Heartbeat::Plan of `reason: "pulse"` Items, which Heartbeat.pulse injects
    # into the normal open!/execute! machinery. Pure read; no writes, no network.
    #
    # Record sources compose as a UNION, deduped by (type, id, context):
    #   - explicit tokens → config.pulse_resolver (else "Type/id"); each record is
    #     paired with EACH context it is a member of (root when it belongs to none),
    #     so `pulse combustion-edge` tends that chapter in its own book's facets.
    #   - context: <key>  → every member of that context.
    # `stale:` is a FILTER, not a source: it keeps only (record, facet) whose source
    # moved since the last tend. It therefore needs a scope — a context and/or
    # explicit targets; collection-wide stale (no scope) is DEFERRED (it would be a
    # full-table Ruby scan, against the engine's set-based discipline — leave it to
    # the nightly beat, or add a set-based path later).
    #
    # Each resolved (record, context) expands to one Item per scheduled facet the
    # context declares (Planner root-fallback when the record is contextless).
    module Pulse
      module_function

      # A directed pulse is for BOUNDED targets (this one thing, these three, a
      # book) — bulk re-tending of a large corpus is the nightly beat's job. A
      # named context over this many members raises loudly rather than loading
      # them all into Ruby and running a per-record staleness query each (the
      # engine's set-based discipline; crs-reports has 35K members). Stub it low
      # in specs to exercise the guard.
      #
      # CONTRACT: a `stale:` context pulse runs source_moved? per member — up to
      # ~2,000 sequential MAX(started_at) queries, the ceiling this cap accepts.
      # RAISING this cap requires making the stale filter set-based FIRST (a
      # memberships ⋈ per-record MAX(started_at) join — the source_change_by_sql
      # shape in the Planner), or the N+1 stops being bounded.
      CONTEXT_MEMBER_CAP = 2_000

      def resolve(targets: [], stale: false, context: nil, budget: nil)
        planner = Enliterator::Heartbeat::Planner.new(budget: budget)
        ctx     = context && Enliterator::Context.find_by(key: context.to_s)
        # A NAMED context that doesn't exist is a caller error (a typo), surfaced
        # loudly and distinctly — NOT the same as an existing-but-empty context,
        # which is the legitimate "nothing to pulse" no-op path.
        if context.present? && ctx.nil?
          raise ArgumentError, "pulse: no context with key #{context.inspect}"
        end
        # stale is a filter; with no scope it would mean "every stale record
        # everywhere" — a full-table scan. Deferred in v1; demand a scope.
        if stale && ctx.nil? && Array(targets).empty?
          raise ArgumentError, "pulse: STALE needs a CONTEXT or explicit TARGETS " \
                               "(collection-wide stale is deferred to the nightly beat)"
        end
        # A large named context is bulk work — bounded loudly, never loaded into
        # Ruby row-by-row. COUNT first (one indexed query) before members_of; the
        # cap covers both the members Ruby-load and the per-record stale filter.
        if ctx
          n = Enliterator::ContextMembership.where(context_id: ctx.id).count
          if n > CONTEXT_MEMBER_CAP
            raise ArgumentError, "pulse: context #{ctx.key.inspect} has #{n} members — a directed " \
                                 "pulse is for bounded targets (≤ #{CONTEXT_MEMBER_CAP}); narrow with " \
                                 "TARGETS or let the nightly beat handle bulk"
          end
        end

        pairs = {}   # [type, id, context_id] => [record, context]
        add   = ->(record, in_ctx) do
          next if record.nil?
          key = [ record.class.name, record.public_send(record.class.primary_key).to_s, in_ctx&.id ]
          pairs[key] ||= [ record, in_ctx ]
        end

        # Explicit tokens pair with each context the record belongs to (root when
        # it belongs to none) — the record knows where it lives.
        Array(targets).each do |token|
          record = resolve_token(token)
          # A named target that doesn't resolve is a misdirected pulse — loud and
          # distinct, exactly like a missing context. Never a silent partial (the
          # engine forbids the "successful operation you didn't fully intend").
          if record.nil?
            raise ArgumentError, "pulse: no record for target #{token.inspect} " \
                                 "(check the identifier, or set config.pulse_resolver)"
          end
          ctxs = contexts_of(record)
          ctxs = [ nil ] if ctxs.empty?
          ctxs.each { |c| add.call(record, c) }
        end
        members_of(ctx).each { |record| add.call(record, ctx) } if ctx

        budget_val = (budget || Enliterator.configuration.heartbeat_budget_tokens).to_i
        items = []
        pairs.each_value do |(record, in_ctx)|
          facets_for(in_ctx).each do |facet|
            next if stale && !source_moved?(record, facet, in_ctx)
            items << Enliterator::Heartbeat::Plan::Item.new(
              tendable_type: record.class.name,
              tendable_id:   record.public_send(record.class.primary_key).to_s,
              facet:         facet.to_s,
              context:       in_ctx,
              reason:        "pulse",
              est_tokens:    planner.estimate(facet)
            )
          end
        end

        Enliterator::Heartbeat::Plan.new(
          budget: budget_val, change_cap: 0, items: items, warnings: planner.warnings,
          frontier_remaining: {}, horizon_tokens: 0
        )
      end

      # --- token + context resolution (host identifier space) -----------------

      def resolve_token(token)
        if (cb = Enliterator.configuration.pulse_resolver)
          cb.call(token)
        elsif token.to_s.include?("/")
          type, id = token.to_s.split("/", 2)
          klass = type.safe_constantize
          klass&.find_by(klass.primary_key => id)
        end
      end

      # The contexts a record is a member of. member_id is a STRING column (host
      # PKs may be uuid), so match on the stringified PK — never AR's polymorphic
      # where(member:), which would send a bigint against the varchar column.
      def contexts_of(record)
        Enliterator::ContextMembership
          .where(member_type: record.class.name,
                 member_id: record.public_send(record.class.primary_key).to_s)
          .includes(:context).filter_map(&:context)
      end

      def members_of(ctx)
        return [] unless ctx
        Enliterator::ContextMembership.where(context_id: ctx.id).includes(:member)
                                      .filter_map(&:member)
      end

      # --- facets + staleness -------------------------------------------------

      # A context: exactly the scheduled facets it declares. Root (contextless):
      # mirror Planner#root_lanes — fall back to config.tending_facets when the
      # policy declares NO root facets at all, so a root pulse matches beat!.
      def facets_for(ctx)
        return Enliterator.staffing.schedulable_facets_declared_in(ctx.key) if ctx
        return Enliterator.staffing.schedulable_facets_declared_in(nil) unless
          Enliterator.staffing.facets_declared_in(nil).empty?
        Array(Enliterator.configuration.tending_facets).map(&:to_s)
      end

      # Source moved since the last succeeded applied visit on this (facet,
      # context)? A never-tended facet returns FALSE — "stale" means a standing
      # claim went out of date, not "untended". Honors config.heartbeat_source_changed
      # (the same signal the pacemaker's source_change lane uses). Bounded: only
      # ever called over a context's members or explicit targets, never the corpus.
      def source_moved?(record, facet, ctx)
        last = Enliterator::Visit
               .where(tendable_type: record.class.name,
                      tendable_id: record.public_send(record.class.primary_key).to_s,
                      facet: facet.to_s, context_id: ctx&.id,
                      status: "succeeded", applied: true)
               .maximum(:started_at)
        return false if last.nil?

        cb = Enliterator.configuration.heartbeat_source_changed
        if cb
          cb.arity == 2 ? cb.call(record, last) : cb.call(record, facet.to_s, last)
        else
          record.respond_to?(:updated_at) && record.updated_at.present? && record.updated_at > last
        end
      end
    end
  end
end
