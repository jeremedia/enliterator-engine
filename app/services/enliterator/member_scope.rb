# frozen_string_literal: true

require "digest"

module Enliterator
  # v0.83 — THE AUDIENCE SCOPE: which records exist, for this reader.
  #
  # The engine read the whole collection on every path: subject-heading
  # counts, semantic search, the catalog grid, connection edges and
  # neighbors. A host serving readers with different entitlements (HSDL: a
  # public tier that must not learn a Full/Registered record EXISTS) cannot
  # correct a count after the fact — a heading count of 14 that includes two
  # withheld theses leaks them, and filtering the values afterwards cannot
  # repair the number. The scope has to apply BEFORE counting and ranking.
  #
  #   Enliterator.with_member_scope(DocMetum.enabled.publicly_visible) do
  #     Enliterator::Mcp.dispatch("browse_subjects", "context" => "chds-theses")
  #   end
  #
  # Within the block, a record exists only if it is in one of the given
  # relations (keyed by their model). Types not named are absent — the scope
  # DENIES by default. Engine Parts follow their record. Nothing outside a
  # block changes: no scope ⇒ every query is byte-identical.
  #
  # Honored by: Embedding.in_context (catalog grid/search, connection
  # neighbors, chat retrieval), the Catalog's claim spine (headings, subject
  # click-through, stats, recently-tended), and every record lookup the MCP
  # tools make. Cache keys carry the scope's digest, so two audiences never
  # share a cached count. MCP tools that do not honor it REFUSE to run inside
  # a scope (Mcp.dispatch fails closed) — a tool added later cannot silently
  # read around it.
  module MemberScope
    KEY = :enliterator_member_scope

    class << self
      # Run the block with +relations+ (one ActiveRecord::Relation or an array)
      # as the visible record set. Nests by replacement; restored on exit.
      def with(relations)
        # NOT Array(relations): Array() on a Relation loads its records.
        rels = relations.is_a?(Array) ? relations : [ relations ]
        raise ArgumentError, "with_member_scope needs at least one relation" if rels.empty?
        rels.each do |r|
          raise ArgumentError, "member scope entries must be ActiveRecord relations (got #{r.class})" \
            unless r.respond_to?(:klass) && r.respond_to?(:to_sql)
        end
        prior = ActiveSupport::IsolatedExecutionState[KEY]
        ActiveSupport::IsolatedExecutionState[KEY] = rels
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[KEY] = prior
      end

      def current = ActiveSupport::IsolatedExecutionState[KEY]
      def active? = current.present?

      # Restrict +relation+ to rows whose polymorphic record (type_sql, id_sql
      # — SQL column expressions holding the record's type name and its id as
      # text) is in the scope. No scope ⇒ +relation+ unchanged.
      def restrict(relation, type_sql:, id_sql:)
        return relation unless active?
        relation.where(Arel.sql(predicate_sql(type_sql: type_sql, id_sql: id_sql)))
      end

      # Is this record visible under the scope? (Always true with no scope.)
      # A Part is visible when its record is.
      def include?(record)
        return true unless active?
        return false if record.nil?
        record = record.record if record.is_a?(Enliterator::Part)
        return false if record.nil?

        current.any? do |rel|
          record.is_a?(rel.klass) && rel.where(rel.klass.primary_key => record.id).exists?
        end
      end

      # Stable per audience: a cache-key fragment. nil with no scope, so an
      # unscoped cache key is byte-identical to the pre-v0.83 key.
      def digest
        return nil unless active?
        "ms-" + Digest::MD5.hexdigest(current.map { |r| "#{r.klass.name}:#{r.to_sql}" }.sort.join("|"))[0, 12]
      end

      private

      # Per scoped model: a CORRELATED probe of the host's primary key,
      #   CASE WHEN type = 'Klass' THEN EXISTS (SELECT 1 FROM klass_table
      #     WHERE klass_table.pk = CAST(id AS <pk type>) AND <relation's where>)
      #   ELSE FALSE END
      # so Postgres checks each candidate row (after whatever else narrowed it)
      # against the pk index. v0.83 used `id IN (SELECT CAST(pk AS TEXT) …)`,
      # which materialized the whole visible set per query — on HSDL ~185K
      # casted ids under every heading pluck, 1–10 s each (v0.83.1). The CASE
      # is load-bearing: AND does not fix evaluation order in Postgres, and
      # casting another type's id (a bigint id to uuid) would raise.
      def predicate_sql(type_sql:, id_sql:)
        clauses = current.map do |rel|
          klass = rel.klass
          conn  = klass.connection
          pk    = "#{klass.quoted_table_name}.#{conn.quote_column_name(klass.primary_key)}"
          sql_type = klass.columns_hash.fetch(klass.primary_key.to_s).sql_type
          probe = rel.unscope(:select, :order, :limit, :offset)
                     .where(Arel.sql("#{pk} = CAST(#{id_sql} AS #{sql_type})"))
                     .select(Arel.sql("1"))
          "(CASE WHEN #{type_sql} = #{conn.quote(klass.name)} THEN EXISTS (#{probe.to_sql}) ELSE FALSE END)"
        end
        "(#{clauses.join(' OR ')})"
      end
    end
  end

end
