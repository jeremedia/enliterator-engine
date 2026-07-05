# frozen_string_literal: true

module Enliterator
  # The collection's CHARTER — its told, extrinsic identity ("The Shape of a
  # Collection" §6). A collection's structure is derivable from its members;
  # its proper noun, purpose, and audience are not — they are the institutional
  # frame AROUND the members, and they must be TOLD. The charter is stored as
  # HUMAN-ATTRIBUTED claims (`attributed_to: "human:…"` — load-bearing: only
  # human% attribution enters `.understanding`, so the charter flows into every
  # notebook and knowledge surface) on the host's ONE-ROW collection tendable
  # (config.collection_tendable, which implies the synthesized mask).
  #
  # Claim keys are PREFIXED (`charter_purpose`, not `purpose`) so the told
  # extrinsic identity can never collide with a future INTRINSIC synthesis
  # claim on the same record — a tended reading of what the collection contains
  # must not supersede what its keepers said it is for.
  #
  # Untold fields are ordinary v0.46 lacunae on the collection record (facet
  # "charter", diagnosis "silent" — the item omits it; an authority, the
  # keepers, may know), opened WITHOUT a visit: the reserved nullability's
  # first real use. A collection that hasn't been told who it is has open,
  # named gaps — not a vague unconfiguredness.
  module Charter
    # Pinned minimal (§6 discipline): DACS's collection-level description and
    # the collection development policy are the ANCHORS, not the schema.
    FIELDS = %w[proper_noun identity purpose audience].freeze
    FACET  = "charter"

    module_function

    def configured?
      Enliterator.configuration.collection_tendable.present?
    end

    def key_for(field) = "charter_#{field}"

    def charter_key?(key) = key.to_s.start_with?("charter_")

    # The one-row collection record. Resolved PER CALL (config resets per spec
    # example; dev reload swaps class objects — never memoize the constant).
    # 0 rows ⇒ nil — the legitimate window between setting the config and
    # seeding the row; the LOUD channels for that state are the heartbeat's
    # run_warnings and the rake report, never a raise inside a page render.
    # >1 rows ⇒ raise — two rows make the identity ambiguous, and no surface
    # should guess.
    def record
      name = Enliterator.configuration.collection_tendable
      return nil if name.blank?

      klass = name.to_s.safe_constantize
      if klass.nil?
        raise ConfigurationError,
              "config.collection_tendable = #{name.inspect} does not name a constant"
      end
      count = klass.count
      if count > 1
        raise ConfigurationError,
              "config.collection_tendable = #{name.inspect} must have exactly one row " \
              "(found #{count}) — the collection's identity cannot be ambiguous"
      end
      klass.first
    end

    # The charter, read pure — told fields from live claims, untold names, and
    # the DERIVED operational values (rendered alongside, never stored as
    # claims: the reading scope lives in config, the reading facets in the
    # staffing policy — duplicating them as claims would fork the truth).
    # nil when unconfigured or the row doesn't exist yet.
    def read
      rec = configured? && record
      return nil unless rec

      claims = rec.enliterator_claims.live.where(key: FIELDS.map { |f| key_for(f) })
                  .index_by(&:key)
      told = FIELDS.each_with_object({}) do |f, h|
        h[f.to_sym] = claims[key_for(f)]&.value
      end

      {
        record: { type: rec.class.name, id: rec.id.to_s },
        told: told.compact,
        untold: FIELDS.select { |f| told[f.to_sym].blank? },
        derived: {
          reading_scope: Enliterator.reading_scope || :collection,
          # The org chart in force at root — honestly "the facets this
          # collection reads for", not the spec's fuller "reading dimensions".
          reading_facets: Enliterator.staffing.facets_declared_in(nil).map(&:to_s)
        }
      }
    end

    # One line for prompts/headers: "Spine — a workshop of sovereign manuscripts".
    def headline
      c = read
      return nil unless c && c[:told][:proper_noun].present?

      [ c[:told][:proper_noun], c[:told][:identity] ].compact.reject(&:blank?).join(" — ")
    end

    # TELL the charter — only the given fields. Semantics per field:
    #   no live claim   → assert_claim! (create; testimony with no history yet)
    #   equal value     → NOOP (correct_claim! doesn't compare — we must, or
    #                     every re-tell mints a redundant supersession)
    #   changed value   → correct_claim! (mint + supersede — the charter is an
    #                     identity DOCUMENT; its edits are auditable history,
    #                     unlike assert's in-place host seeds)
    # Both paths land human-attributed ("human:<by>") → `.understanding`.
    # Telling a field closes its open charter lacuna.
    def tell!(by: "curator", **fields)
      rec = record
      raise ConfigurationError, "no collection record to tell (create the #{Enliterator.configuration.collection_tendable} row first)" if rec.nil?

      told = {}
      fields.slice(*FIELDS.map(&:to_sym)).each do |field, value|
        next if value.nil?

        key  = key_for(field)
        live = rec.enliterator_claims.live.find_by(key: key)
        told[field] =
          if live.nil?
            rec.assert_claim!(key: key, value: value, attributed_to: "human:#{by}")
            :told
          elsif live.value == value
            :unchanged
          else
            rec.correct_claim!(live, value: value, note: by)
            :superseded
          end

        Enliterator::Lacuna.open.find_by(tendable: rec, facet: FACET, key: key, context_id: nil)
                           &.close!(reason: "supplied")
      end
      told
    end

    # Open a lacuna per untold field; close lacunae for told ones. The write
    # half of the onboarding surface — called by the heartbeat charter step and
    # the rake, NEVER by read (surfaces stay pure).
    def reconcile_gaps!
      rec = record
      return { opened: 0, closed: 0 } if rec.nil?

      c = read
      opened = 0
      closed = 0
      FIELDS.each do |field|
        key = key_for(field)
        if c[:untold].include?(field)
          Enliterator::Lacuna.open_or_refresh(
            tendable: rec, facet: FACET, key: key, diagnosis: "silent", visit: nil,
            note: "the collection has not been told its #{field.tr('_', ' ')} — " \
                  "tell it: rake enliterator:charter #{field.upcase}=\"…\""
          )
          opened += 1
        else
          gone = Enliterator::Lacuna.open.find_by(tendable: rec, facet: FACET, key: key, context_id: nil)
          if gone
            gone.close!(reason: "supplied")
            closed += 1
          end
        end
      end
      { opened: opened, closed: closed }
    end
  end
end
