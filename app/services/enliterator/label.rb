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
        recs  = (klass && Enliterator.tendable_type?(klass)) ? klass.where(id: ids).index_by { |r| r.id.to_s } : {}
        ids.each do |id|
          rec = recs[id.to_s]
          out[[ type, id ]] = { title: one(rec, type: type, id: id), position: rec&.try(:position) }
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
