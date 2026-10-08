# frozen_string_literal: true

module Enliterator
  # v0.90: one event in this database's lineage (see the migration). Only one
  # deployment curates: the one whose enliteration was AUTHORED here or
  # declared authoritative — never a copy made by import.
  class LineageEvent < ApplicationRecord
    self.table_name = "enliterator_lineage_events"

    KINDS = %w[import authority].freeze
    validates :kind, inclusion: { in: KINDS }

    class << self
      # The table may not exist yet on a host running this engine ahead of its
      # migration (the bundler-override seam): treat that as no lineage.
      def available?
        return @available if defined?(@available) && @available

        @available = connection.data_source_exists?(table_name)
      end

      def latest = (available? ? order(:created_at, :id).last : nil)
      def last_import = (available? ? where(kind: "import").order(:created_at, :id).last : nil)

      # Is this database a copy — its latest lineage event an import?
      def copy? = latest&.kind == "import"

      def record_import!(manifest)
        return nil unless available?

        exported = manifest["generated_at"].presence && (Time.iso8601(manifest["generated_at"]) rescue nil)
        create!(kind: "import", source_label: manifest["exported_from"].presence || manifest["host"],
                source_exported_at: exported, created_at: Time.current)
      end

      def declare_authority!(note: nil)
        raise ActiveRecord::StatementInvalid, "enliterator_lineage_events is not migrated" unless available?

        create!(kind: "authority", note: note, created_at: Time.current)
      end
    end
  end
end
