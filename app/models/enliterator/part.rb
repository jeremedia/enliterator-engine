module Enliterator
  # v0.25: a PART — one section of a host record, as a first-class tendable
  # (the cataloger's ANALYTICAL ENTRY: libraries have always described parts
  # of dense works; the economics just never allowed it at scale). Including
  # Tendable gives parts the whole loop — visits, claims, reconciliation,
  # escalation, suggestions, audit grounding, embeddings, trajectories —
  # polymorphically, with no special cases. Parts are engine-internal: they
  # do NOT enter the tendable registry (see Tendable's registration rule),
  # so they never appear in planner root lanes, the corpus census, or the
  # condition survey. Their tending is orchestrated (Tending::Reading).
  #
  # The text is a stored COPY of the slice: content_digest is then stable
  # evidence — a part's claims were grounded in exactly these bytes — and
  # the audit examiner can verify against them no matter what later
  # re-conversions do to the parent.
  class Part < ApplicationRecord
    include Enliterator::Tendable

    belongs_to :record, polymorphic: true

    validates :ordinal, presence: true,
                        uniqueness: { scope: [ :record_type, :record_id ] }

    # The label contract (Conversation, Catalog cards, Atlas nodes all read
    # try(:title) first): a part presents as its heading.
    def title
      heading.presence || "Section #{ordinal}"
    end

    def to_enliterator_text(facet: nil)
      [ heading.presence, text ].compact.join("\n\n")
    end

    # Reconcile a record's parts against freshly-sectioned +sections+
    # ([{heading:, text:}, ...] in document order, the host's
    # `to_enliterator_parts` contract). Matched by ORDINAL: an existing part
    # whose content changed is updated in place (its claims survive — they
    # hang on the part row; the digest change moves updated_at, the
    # source-change hook for future re-reads), missing ordinals are created,
    # trailing extras are destroyed (their claims cascade — a vanished
    # section's notes vanish honestly). Returns the parts in order.
    def self.refresh_for!(record, sections)
      sections = Array(sections)
      existing = where(record: record).index_by(&:ordinal)
      offset   = 0

      kept = sections.each_with_index.map do |section, i|
        heading = section[:heading] || section["heading"]
        text    = (section[:text] || section["text"]).to_s
        digest  = Digest::MD5.hexdigest(text)
        attrs   = { heading: heading, text: text, content_digest: digest,
                    char_start: offset, char_end: offset + text.length }
        offset += text.length

        part = existing[i]
        if part.nil?
          create!(record: record, ordinal: i, **attrs)
        elsif part.content_digest != digest || part.heading != heading
          part.update!(**attrs)
          part
        else
          part
        end
      end

      where(record: record).where("ordinal >= ?", sections.size).destroy_all
      kept
    end

    # The NOTEBOOK: the record's accumulated reading notes, assembled as the
    # synthesis pass's source text — every part in order, each live analysis
    # claim as a "key: value" line under its heading. This is what the host's
    # `to_enliterator_text` returns for work-level facets once notes exist,
    # which means the audit examiner verifies synthesis claims against the
    # SAME notebook (a derivation audit — named in SPEC, not pretended away).
    def self.notebook_for(record, context: nil, value_cap: 400)
      parts = where(record: record).order(:ordinal).includes(:enliterator_claims)
      blocks = parts.filter_map do |part|
        claims = part.enliterator_claims.live
        claims = claims.where(context_id: context.scope_ids) if context
        lines = claims.order(:key).map do |c|
          v = c.value.is_a?(String) ? c.value : c.value.to_json
          v = "#{v[0, value_cap]}…" if v.length > value_cap
          "#{c.key}: #{v}"
        end
        next if lines.empty?
        "## #{part.title}\n#{lines.join("\n")}"
      end
      return "" if blocks.empty?
      "READING NOTES (per section, from the collection's own analysis):\n\n#{blocks.join("\n\n")}"
    end
  end
end
