module Enliterator
  # v0.46: the Lacuna — a first-class record of an expected-but-absent fact (the
  # negative space of a Claim), sibling to Suggestion/Treatment. Opened when a
  # *required* term comes back unmet during tending, diagnosed as to WHY (a hint,
  # not a verdict), refreshed each beat it stays missing, and closed when a later
  # visit supplies the value. This is the engine's enumeration of its own gaps.
  #
  # The epistemic triad: frontier (unknown-unknown) / lacuna (known-unknown) /
  # claim (known-known). Lacunae are EARNED by looking — born at tend-time, never
  # pre-stamped. Gated behind config.record_lacunae (default off) ⇒ empty table ⇒
  # byte-identical.
  class Lacuna < ApplicationRecord
    # "Lacuna" pluralizes irregularly (the Latin plural is "lacunae", which the
    # migration uses); pin the table name rather than teach Rails the inflection.
    self.table_name = "enliterator_lacunae"

    belongs_to :tendable, polymorphic: true
    belongs_to :context, class_name: "Enliterator::Context", optional: true
    # Both visit links are optional (bare nullable columns, no DB FK), matching
    # Claim#visit. detected_in_visit is always set in v0.46 (every open comes from
    # a real tending visit); its nullability is a forward declaration for v0.47
    # Context-level lacunae opened by a shape-visit.
    belongs_to :detected_in_visit, class_name: "Enliterator::Visit", optional: true
    belongs_to :closed_by_visit,   class_name: "Enliterator::Visit", optional: true

    STATUSES = %w[open closed].freeze
    # A checkability taxonomy: defective_surrogate = the fact is in the item but our
    # extraction lost it (re-extract); silent = the item omits it, an authority may
    # know (look elsewhere); not_identified = genuinely unrecoverable (no check
    # exists — the RDA conventional state); undiagnosed = gap certain, cause not
    # assessed (the engine's no-info default; the model never returns it itself).
    DIAGNOSES = %w[defective_surrogate silent not_identified undiagnosed].freeze
    CLOSED_REASONS = %w[supplied dismissed not_identified_confirmed].freeze

    # status is a plain string column with a scope (NOT an AR enum — an enum would
    # generate an `open`/`open!` that shadows the class method and the scope).
    scope :open, -> { where(status: "open") }

    # Open a lacuna for an unmet required term, or refresh the existing open one
    # (idempotent per (tendable, facet, key, context)). An unknown or omitted
    # diagnosis is coerced to "undiagnosed" — never raised, never stored off-enum
    # (the model owns the three substantive values; the engine owns undiagnosed).
    # A re-detection bumps detections/last_detected_at and preserves a prior
    # substantive diagnosis (an undiagnosed beat never overwrites a good one).
    #
    # The create is wrapped in a savepoint (requires_new) so a RecordNotUnique
    # from a concurrent insert (a manual tend! overlapping the pacemaker) rolls
    # back the savepoint, not any caller transaction, and we re-find + bump. The
    # unique index implies the conflicting row is committed, so the re-find sees it.
    def self.open_or_refresh(tendable:, facet:, key:, context: nil, diagnosis: nil, note: nil, visit: nil)
      diag  = DIAGNOSES.include?(diagnosis.to_s) ? diagnosis.to_s : "undiagnosed"
      attrs = { tendable: tendable, facet: facet.to_s, key: key.to_s, context_id: context&.id }

      if (lac = open.find_by(**attrs))
        return bump!(lac, diag, note)
      end

      transaction(requires_new: true) do
        create!(**attrs, status: "open", diagnosis: diag, note: note,
                detected_in_visit_id: visit&.id, last_detected_at: Time.current, detections: 1)
      end
    rescue ActiveRecord::RecordNotUnique
      lac = open.find_by(**attrs)
      lac ? bump!(lac, diag, note) : raise
    end

    # Close an open lacuna — the value was supplied (or a curator dismissed it).
    def close!(by_visit: nil, reason: "supplied")
      update!(status: "closed", closed_reason: reason, closed_by_visit_id: by_visit&.id)
    end

    # Bump an existing open lacuna: increment detections, restamp last_detected_at,
    # update note, and update diagnosis ONLY when the new one is substantive (an
    # undiagnosed re-detection preserves a prior real diagnosis).
    def self.bump!(lac, diag, note)
      new_diag = diag == "undiagnosed" ? lac.diagnosis : diag
      lac.update!(diagnosis: new_diag, note: note,
                  last_detected_at: Time.current, detections: lac.detections + 1)
      lac
    end
    private_class_method :bump!
  end
end
