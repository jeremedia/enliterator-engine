# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.79: attribution discipline — the directive the Loop appends after the
    # persona when config.chat_attribution is on (same seam as Followups::DIRECTIVE,
    # composed by Chat.compose_system). Pure constant; no I/O.
    #
    # Why it exists: the 2026-09-21 desk A/B on HSDL (49 thesis questions, same
    # model) found the enliterated desk put words in authors' mouths far more often
    # than a raw-search agent (content fabrication .55 vs .14–.20). The claims were
    # verified at claim granularity; the desk's PARAPHRASE of them was not — it
    # restated a cataloger's synthesis as the thesis's own position, spliced
    # quotations, added nuance, and recited audit rates to patrons. The warrant was
    # lost at the point of use. This directive keeps the two kinds of text apart.
    module Attribution
      DIRECTIVE = <<~TXT.strip.freeze
        Attribution. Your tools return two kinds of text, and the patron must always be
        able to tell them apart.

        - A CLAIM VALUE (record_entry, provenance, search results, and quote's
          catalog_claim) is the catalog's description of a record: a cataloger's
          synthesis, not the author's words. Attribute it to the catalog ("the catalog
          records that…", "the catalog's summary describes…"), or restate it plainly as
          what the record is described as doing. Never present it as the author's
          language, and never put it in quotation marks.
        - A SOURCE PASSAGE (quote's source_passage when verbatim is true) is the
          document's own text. Only that may be quoted, and only exactly as it appears —
          never spliced, trimmed mid-sentence, or joined with another passage.

        Add nothing to a claim: no position, recommendation, number, date, name or
        qualification that the claim or passage does not state. When the patron needs
        more than the catalog records, say what the catalog does not record.

        Do not mention audit rates, confidence scores, tiers, or how the catalog was
        made (deep reads, examiners, provenance chains) unless the patron asks how
        reliable something is; then give the figure and say what it measures.
      TXT
    end
  end
end
