module Enliterator
  # v0.62: the ONE label contract, hoisted from SuggestionsController#record_labels —
  # title → name → "Type #id", so no UUID faces a reviewer. Used by the Requests
  # evidence rows and the Review queue. (Three known siblings of the same convention
  # remain in place — Catalog#label_for, Mcp::Tool.label_for, Atlas#record_label —
  # their signatures differ and they carry their own specs; fold when next touched.)
  module Label
    module_function

    # Batched: [[type, id], ...] → {[type, id] => {title:, position:}}. One query per
    # type, allow-listed via Enliterator.tendable_type? (never constantize-and-load an
    # arbitrary class name from stored data). Position = the host's `position` if it
    # has one (an ordered composite work — a manuscript's chapters); nil for a
    # bag-of-documents corpus.
    def for(pairs)
      pairs.group_by(&:first).each_with_object({}) do |(type, ps), out|
        klass = type.to_s.safe_constantize
        ids   = ps.map(&:last)
        recs  =
          if klass && Enliterator.tendable_type?(klass)
            # Select ONLY the label columns. Host rows can be megabytes (extracted
            # text, serialized analysis) — loading ~1,300 whole theses to read their
            # titles made Requests a four-second page (3.9s in this one call).
            # A model whose title/name is COMPUTED declares the columns it needs via
            # `label_column_names` (Enliterator::Part: heading + ordinal); without the
            # declaration we select the conventional columns that exist.
            cols  =
              if klass.respond_to?(:label_column_names)
                (Array(klass.label_column_names).map(&:to_s) | %w[id]) & klass.column_names
              else
                klass.column_names & %w[id title name position]
              end
            scope = klass.where(id: ids)
            scope = scope.select(*cols) if cols.size > 1
            scope.index_by { |r| r.id.to_s }
          else
            {}
          end
        ids.each do |id|
          rec = recs[id.to_s]
          out[[ type, id ]] =
            begin
              { title: one(rec, type: type, id: id), position: rec&.try(:position) }
            rescue ActiveModel::MissingAttributeError
              # A host that COMPUTES its title/name/position from columns outside the
              # narrow select lands here — take the contract's honest floor ("Type #id")
              # rather than loading megabyte rows for a label.
              { title: "#{type.to_s.demodulize} ##{id}", position: nil }
            end
        end
      end
    end

    # A single, already-loaded record (Review eager-loads the tendable) — or nil,
    # which falls through to the honest "Type #id".
    def one(rec, type:, id:)
      rec&.try(:title).presence || rec&.try(:name).presence || "#{type.to_s.demodulize} ##{id}"
    end
  end
end
