module Enliterator
  # v0.18: one examination of one claim — quality review for the claim store
  # (the cataloger's "revision" function, distinct from authority control).
  # source: "examiner" (the LLM, Audit::Examiner) or "human" (the anchor — the
  # only independent ground truth the instrument has). Multiple audits per
  # claim are the design: examiner verdicts are CALIBRATED by human ones.
  #
  # Append-only by convention. Accuracy is a PROCESS rate: audits never age
  # out when their claim is superseded — a live-only rate would let re-tending
  # launder the number (every supersession swaps an audited claim for an
  # unaudited one). The class methods (sample/accuracy/anchor_agreement) are
  # the instrument; Audit::Examiner renders the LLM verdicts.
  class Audit < ApplicationRecord
    VERDICTS = %w[supported unsupported contradicted unverifiable].freeze
    SOURCES  = %w[examiner human].freeze
    # supported vs DEFECTIVE is the binary the anchor-agreement headline uses;
    # unverifiable pairs are excluded from agreement entirely.
    DEFECTIVE = %w[unsupported contradicted].freeze

    belongs_to :claim, class_name: "Enliterator::Claim"
    belongs_to :corrected_claim, class_name: "Enliterator::Claim", optional: true
    belongs_to :heartbeat, class_name: "Enliterator::Heartbeat", optional: true

    validates :verdict, inclusion: { in: VERDICTS }
    validates :source,  inclusion: { in: SOURCES }

    scope :examiner, -> { where(source: "examiner") }
    scope :human,    -> { where(source: "human") }

    def defective? = DEFECTIVE.include?(verdict)
  end
end
