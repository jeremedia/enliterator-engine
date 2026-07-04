# frozen_string_literal: true

module Enliterator
  class Topology
    # Derives the per-whole Contexts from the declared topology and reconciles
    # their memberships against the host grouping — the Context as a VIEW of the
    # grouping ("The Shape of a Collection" §7), never hand-maintained.
    #
    # Per whole row: find its derived Context (by derived_from), else ADOPT an
    # existing hand-curated context with the same key (stamping it — how a
    # pre-topology host seed becomes the derived context), else create. Key and
    # name FOLLOW the whole (the grouping is the source of truth) — except a key
    # rename is refused when the old key carries declared policy facets (the
    # staffing policy joins context blocks BY KEY; renaming would silently detach
    # them). Key collisions across DIFFERENT wholes raise with both wholes named —
    # never auto-suffixed (silent drift). Key format violations raise — never
    # normalized (normalization creates key↔host-value drift).
    #
    # Membership is MACHINE-OWNED for the DECLARED member type only: every member
    # by foreign key (the whole's HOLDINGS — drafts included), inserted
    # idempotently; rows of the declared type that no longer match the grouping
    # are deleted (also the tombstone sweep for destroyed members). Hand-placed
    # members of other types survive — the machine owns what it declared, nothing
    # more. Every batch is counted and logged; nothing is removed silently.
    #
    # Failure modes: `fail_soft: false` (the rake — an operator is present) lets
    # errors raise. `fail_soft: true` (the heartbeat step) contains each error to
    # its declaration/whole and records it as a warning — one bad slug must not
    # halt the collection's nightly tending (the bedrock-lapse philosophy).
    class Sync
      Result = Struct.new(:created, :adopted, :renamed, :members_added, :members_removed,
                          :orphans_removed, :warnings, :lines, keyword_init: true) do
        def summary
          "contexts created=#{created} adopted=#{adopted} renamed=#{renamed} " \
            "members added=#{members_added} removed=#{members_removed} orphans removed=#{orphans_removed}" \
            "#{warnings.any? ? " warnings=#{warnings.size}" : ''}"
        end
      end

      def self.run!(topology: Enliterator.configuration.topology, fail_soft: false)
        new(topology, fail_soft: fail_soft).run!
      end

      def initialize(topology, fail_soft: false)
        @topology  = topology
        @fail_soft = fail_soft
        @result = Result.new(created: 0, adopted: 0, renamed: 0, members_added: 0,
                             members_removed: 0, orphans_removed: 0, warnings: [], lines: [])
      end

      def run!
        raise Enliterator::ConfigurationError, "no topology declared" if @topology.nil? || !@topology.declares_wholes?

        @topology.wholes.each do |decl|
          contain(decl: decl) do
            bridge_warning(decl)
            sync_declaration(decl)
          end
        end
        @result
      end

      private

      KEY_FORMAT = /\A[a-z0-9][a-z0-9\-]*\z/

      def sync_declaration(decl)
        whole_klass = decl.whole_class
        seen_ids = []

        whole_klass.find_each do |whole|
          contain(decl: decl, whole: whole) do
            seen_ids << whole.id.to_s
            ctx = resolve_context(decl, whole)
            reconcile_members(decl, whole, ctx)
          end
        end

        sweep_orphans(decl, seen_ids)
      end

      # Find-or-derive the whole's Context. Adoption (stamping a same-key
      # hand-curated context) is logged loudly — it converts curator-owned
      # membership to machine-owned membership on this very run.
      def resolve_context(decl, whole)
        key  = fetch_key(decl, whole)
        name = whole.public_send(decl.context_name).to_s.presence || key

        ctx = Enliterator::Context.find_by(derived_from_type: decl.whole_type,
                                           derived_from_id: whole.id.to_s)
        return follow_whole(decl, ctx, key, name) if ctx

        if (existing = Enliterator::Context.find_by(key: key))
          if existing.derived_from_type.nil?
            existing.update!(derived_from_type: decl.whole_type, derived_from_id: whole.id.to_s,
                             name: name)
            @result.adopted += 1
            line "ADOPTED context #{key.inspect} (was hand-curated) as derived from " \
                 "#{decl.whole_type}/#{whole.id} — its #{decl.member_type} membership is now machine-owned"
            existing
          else
            raise Enliterator::ConfigurationError,
                  "context key #{key.inspect} is already derived from " \
                  "#{existing.derived_from_type}/#{existing.derived_from_id}, but " \
                  "#{decl.whole_type}/#{whole.id} produces the same key — the topology's " \
                  "context_key (#{decl.context_key.inspect}) is not unique across wholes; " \
                  "declare a globally unique context_key column on #{decl.whole_type}"
          end
        else
          created = Enliterator::Context.create!(key: key, name: name,
                                                 derived_from_type: decl.whole_type,
                                                 derived_from_id: whole.id.to_s)
          @result.created += 1
          line "created context #{key.inspect} for #{decl.whole_type}/#{whole.id}"
          created
        end
      end

      # Key + name follow the whole. A key rename is refused when the old key has
      # declared policy facets (the policy joins by key — a rename would silently
      # detach a host's `context "key" do ... end` block).
      def follow_whole(decl, ctx, key, name)
        if ctx.key != key
          if Enliterator.staffing.declared_context_keys.include?(ctx.key)
            raise Enliterator::ConfigurationError,
                  "refusing to rename context key #{ctx.key.inspect} → #{key.inspect} " \
                  "(#{decl.whole_type}/#{ctx.derived_from_id}): the staffing policy declares " \
                  "facets for #{ctx.key.inspect} — update the policy's context block first"
          end
          line "renamed context #{ctx.key.inspect} → #{key.inspect} (following #{decl.whole_type})"
          ctx.update!(key: key, name: name)
          @result.renamed += 1
        elsif ctx.name != name
          ctx.update!(name: name)
        end
        ctx
      end

      def fetch_key(decl, whole)
        key = whole.public_send(decl.context_key).to_s
        unless key.match?(KEY_FORMAT)
          raise Enliterator::ConfigurationError,
                "#{decl.whole_type}/#{whole.id} produces context key #{key.inspect}, which does " \
                "not match the required format #{KEY_FORMAT.inspect} — keys are never normalized " \
                "(normalization drifts from the host value); supply a conforming context_key"
        end
        key
      end

      # The holdings, reconciled set-based + idempotently. Deletes are scoped to
      # the DECLARED member type: a curator's hand-placed member of another type
      # survives; a declared-type row that stopped matching the grouping (moved
      # or destroyed) is removed — and counted, never silent.
      def reconcile_members(decl, whole, ctx)
        member_klass = decl.member_class
        ids = member_klass.where(decl.foreign_key => whole.id).pluck(member_klass.primary_key).map(&:to_s)

        now = Time.current
        if ids.any?
          rows = ids.map do |id|
            { context_id: ctx.id, member_type: decl.member_type, member_id: id,
              created_at: now, updated_at: now }
          end
          inserted = Enliterator::ContextMembership.insert_all(
            rows, unique_by: "idx_enliterator_memberships_uniqueness"
          )
          added = inserted.rows.size
          if added.positive?
            @result.members_added += added
            line "context #{ctx.key.inspect}: +#{added} #{decl.member_type} member(s)"
          end
        end

        removed = Enliterator::ContextMembership
                    .where(context_id: ctx.id, member_type: decl.member_type)
                    .where.not(member_id: ids)
                    .delete_all
        if removed.positive?
          @result.members_removed += removed
          line "context #{ctx.key.inspect}: -#{removed} stale #{decl.member_type} member(s) " \
               "(no longer in the grouping, or destroyed)"
        end
      end

      # A destroyed whole leaves an orphan derived context. Remove it only when
      # nothing references it (claims/visits/suggestions could, once a host
      # declares context facets); otherwise keep it and say so.
      def sweep_orphans(decl, seen_ids)
        Enliterator::Context.where(derived_from_type: decl.whole_type)
                            .where.not(derived_from_id: seen_ids).find_each do |ctx|
          if context_referenced?(ctx)
            warn_line "orphan derived context #{ctx.key.inspect} (#{decl.whole_type}/" \
                      "#{ctx.derived_from_id} is gone) kept: claims/visits/suggestions reference it"
          else
            ctx.destroy!   # memberships cascade (dependent: :destroy)
            @result.orphans_removed += 1
            line "removed orphan derived context #{ctx.key.inspect} " \
                 "(#{decl.whole_type}/#{ctx.derived_from_id} no longer exists)"
          end
        end
      end

      def context_referenced?(ctx)
        Enliterator::Claim.where(context_id: ctx.id).exists? ||
          Enliterator::Visit.where(context_id: ctx.id).exists? ||
          Enliterator::Suggestion.where(context_id: ctx.id).exists?
      end

      # Topology does NOT imply the synthesized mask (the flags are orthogonal —
      # a whole need not be a Tendable at all). But a whole that IS a Tendable and
      # is NOT masked will be scheduled by the pacemaker on the member facets,
      # which is almost never intended — warn. (Checked here, not at boot: classes
      # are reliably loaded at sync time.)
      def bridge_warning(decl)
        klass = decl.whole_class
        return unless klass.include?(Enliterator::Tendable)
        return if Enliterator.synthesized_tendable_names.include?(decl.whole_type)

        warn_line "#{decl.whole_type} is a declared whole AND a Tendable but is not in " \
                  "config.synthesized_tendables — the pacemaker will schedule it on root lanes"
      end

      # fail_soft contains an error to its declaration/whole as a warning and
      # continues; fail-hard re-raises (the rake, operator present).
      def contain(decl:, whole: nil)
        yield
      rescue Enliterator::Heartbeat::StoodDown
        raise
      rescue => e
        raise unless @fail_soft

        where = [ decl.whole_type, whole && "/#{whole.id}" ].compact.join
        warn_line "topology sync (#{where}): #{e.class}: #{e.message}"
      end

      def line(msg)
        @result.lines << msg
      end

      def warn_line(msg)
        @result.warnings << msg
        @result.lines << "WARNING: #{msg}"
      end
    end
  end
end
