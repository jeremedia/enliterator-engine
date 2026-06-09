module Enliterator
  # v0.17 — the collection shelf-reads itself. Digital preservation's ladder,
  # built IN to its standards: inventory/link-checking (present), fixity &
  # format validation (intact), extraction quality (legible) — each a
  # host-registered PROBE, mechanical, no LLM. Rung 4 (intelligible) is never
  # probed: the tending loop is the instrument, and `residue` is its reading.
  #
  #   Enliterator::Condition.register(:availability) do |record|
  #     { ok: record.url_alive?, code: "url_dead",
  #       remediation: "supply a replacement URL or upload the PDF",
  #       note: "link unreachable", signals: { checked_at: ... } }
  #   end
  #   Enliterator::Condition.register(:legibility, gates_tending: true) { ... }
  #
  # Probe contract: return nil for NOT APPLICABLE (skipped, counted); else
  # {ok:, code:, signals:, remediation:, note:}. `code` is a machine-stable
  # snake_case token with NO record-specific content — it builds the failure
  # SIGNATURE the piles group by and the conservator's treatments key on.
  # A probe registered with `gates_tending: true` answers "can the ENGINE
  # read this record" — its failure makes the record UNTENDABLE (score 0.0,
  # excluded from every tending queue). Any other failure is DEGRADED (0.5):
  # a patron-side problem; the library kept a surrogate, tending proceeds.
  # NO short-circuit between probes for the same reason — a dead link with
  # cached full text must still pass legibility.
  #
  # Surveys write Measure rows (the model is shared; the CADENCE is not —
  # probes never run per-tend, so they live in this registry, not Measures').
  module Condition
    ROLLUP = "condition"
    PROBE_PREFIX = "condition_"
    BANDS = { sound: 1.0, degraded: 0.5, untendable: 0.0 }.freeze
    NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/
    FALLBACK_CODE = "failed"
    CLAIM_KEY = "source_status"

    @registry = {}   # name(Symbol) => { block:, gates_tending:, position: }

    module_function

    # ---- registration --------------------------------------------------------

    def register(name, gates_tending: false, &block)
      n = name.to_s
      raise ArgumentError, "probe name must be snake_case (got #{n.inspect})" unless n.match?(NAME_FORMAT)
      if n == ROLLUP || n.start_with?(ROLLUP)
        raise ArgumentError, "probe name may not be or begin with #{ROLLUP.inspect} — " \
                             "the rollup namespace is reserved (the gate depends on it)"
      end
      @registry[n.to_sym] = { block: block, gates_tending: gates_tending, position: @registry.size + 1 }
      n.to_sym
    end

    def registry = @registry
    def reset_registry! = @registry = {}
    def probes_registered? = @registry.any?

    # DB-side adoption: any survey has ever written a rollup row. The planner
    # gate and the conservation report key on THIS, not on registration.
    def adopted?
      Enliterator::Measure.where(name: ROLLUP).exists?
    end

    # ---- the survey -----------------------------------------------------------

    def survey!(record)
      survey_batch!([ record ]).first
    end

    # Run every probe over `records`, upsert one Measure row per (record,
    # probe) plus the ROLLUP row carrying band + signature, and keep the
    # source_status claim honest. Returns per-record verdict hashes.
    def survey_batch!(records)
      records = Array(records)
      return [] if records.empty?
      if registry.empty?
        log("survey skipped — no condition probes registered")
        return []
      end

      now = Time.current
      rows = []
      verdicts = []
      not_applicable = 0
      probe_errors = 0

      records.each do |record|
        failing = {}
        applicable = 0

        registry.each do |name, probe|
          result =
            begin
              probe[:block].call(record)
            rescue => e
              probe_errors += 1
              log("probe #{name} errored on #{record.class.name}/#{record.id}: #{e.class}: #{e.message}")
              rows << measure_row(record, "#{PROBE_PREFIX}#{name}", nil,
                                  { "probe_error" => "#{e.class}: #{e.message}" }, now)
              # Instrument failure ≠ record failure: excluded from the rollup.
              :errored
            end
          next if result == :errored
          if result.nil?
            not_applicable += 1
            next
          end

          applicable += 1
          ok = !!result[:ok]
          code = (result[:code].presence || FALLBACK_CODE).to_s
          signals = (result[:signals] || {}).merge("ok" => ok, "code" => (ok ? nil : code)).compact
          rows << measure_row(record, "#{PROBE_PREFIX}#{name}", ok ? 1.0 : 0.0, signals, now)

          unless ok
            log("probe #{name} returned a failure with no code — pile will be coarse (#{FALLBACK_CODE})") if result[:code].blank?
            failing[name.to_s] = {
              "code"        => code,
              "note"        => result[:note].to_s.presence,
              "remediation" => result[:remediation].to_s.presence,
              "gates"       => probe[:gates_tending]
            }.compact
          end
        end

        band = band_for(failing, applicable)
        signature = signature_for(failing)
        rows << measure_row(record, ROLLUP, BANDS[band],
                            { "band" => band.to_s, "signature" => signature,
                              "failing" => failing, "applicable" => applicable }.compact, now)
        reconcile_claim!(record, band, failing)
        verdicts << { record: record, band: band, signature: signature, failing: failing }
      end

      log("#{not_applicable} probe run(s) not applicable in this batch") if not_applicable.positive?
      log("#{probe_errors} probe error(s) in this batch — see per-record signals") if probe_errors.positive?

      Enliterator::Measure.upsert_all(rows, unique_by: "idx_enliterator_facets_on_tendable_and_name") if rows.any?
      verdicts
    end

    # untendable iff a gates_tending probe failed (the engine cannot read it);
    # degraded for any other failure (patron-side); sound otherwise. A record
    # with zero applicable probes is sound by presumption (and logged above).
    def band_for(failing, _applicable)
      return :untendable if failing.values.any? { |f| f["gates"] }
      return :degraded if failing.any?
      :sound
    end

    # Stable fingerprint: failing "probe:code" pairs, sorted, joined "+".
    # No rungs, no error text — registry renumbering or message drift must
    # never orphan a treatment row.
    def signature_for(failing)
      return nil if failing.empty?
      failing.map { |probe, f| "#{probe}:#{f['code']}" }.sort.join("+")
    end

    # The catalog note. Asserted at UNTENDABLE only by default (a degraded
    # claim on thousands of dead-link records would tax every future prompt
    # via literacy_state); config.condition_claim_scope = :all opts in.
    # Retracted when the record returns inside scope — resolution is measured.
    def reconcile_claim!(record, band, failing)
      scope = Enliterator.configuration.condition_claim_scope
      claim_worthy = band == :untendable || (scope == :all && band == :degraded)

      if claim_worthy
        note = failing.values.filter_map { |f| f["note"] || f["code"] }.join("; ")
        record.assert_claim!(key: CLAIM_KEY, value: "#{band}: #{note}",
                             locked: true, attributed_to: "condition-survey")
      else
        record.retract_claim!(key: CLAIM_KEY)
      end
    end

    # ---- reading the shelf -----------------------------------------------------

    # Failure piles, LIVE: grouped by signature over current rollup rows.
    # [{signature:, band:, count:, failing:, samples: [[type, id], ...]}]
    def piles(sample_limit: 3)
      scope = Enliterator::Measure.where(name: ROLLUP).where("score < 1.0")
      counts = scope.group(Arel.sql("signals->>'signature'")).count
      counts.sort_by { |_, c| -c }.map do |signature, count|
        sample_rows = scope.where("signals->>'signature' = ?", signature)
                           .order(computed_at: :desc).limit(sample_limit)
        first = sample_rows.first
        {
          signature: signature,
          band:      first&.signals&.dig("band"),
          count:     count,
          failing:   first&.signals&.dig("failing") || {},
          samples:   sample_rows.map { |m| [ m.tendable_type, m.tendable_id ] }
        }
      end
    end

    def untendable_count
      Enliterator::Measure.where(name: ROLLUP, score: 0.0).count
    end

    def surveyed_count
      Enliterator::Measure.where(name: ROLLUP).count
    end

    # ---- rung 4: the residue ---------------------------------------------------

    # Records the engine READ (≥ min_visits succeeded applied visits), whose
    # condition is SOUND, and which hold ZERO live ENGINE-DERIVED claims.
    # The visit_id IS NOT NULL discriminator is load-bearing: locked/host
    # claims (source_status itself, assert_claim! seeds) must never
    # self-certify a record as understood. A NOOP-stable record keeps its
    # derived claims and is healthy; a never-understood record has none.
    RESIDUE_SIGNATURE = "rung4:never_understood"

    def residue(min_visits: 2, limit: 50)
      rows = ActiveRecord::Base.connection.select_rows(
        ActiveRecord::Base.sanitize_sql_array([ <<~SQL, min_visits, limit ])
          SELECT v.tendable_type, v.tendable_id, COUNT(*) AS ok_visits, MAX(v.confidence) AS best_conf
          FROM enliterator_visits v
          WHERE v.status = 'succeeded' AND v.applied
          GROUP BY v.tendable_type, v.tendable_id
          HAVING COUNT(*) >= ?
          AND NOT EXISTS (
            SELECT 1 FROM enliterator_claims c
            WHERE c.tendable_type = v.tendable_type AND c.tendable_id = v.tendable_id
              AND c.superseded_by_id IS NULL AND c.status <> 'superseded'
              AND c.visit_id IS NOT NULL)
          AND EXISTS (
            SELECT 1 FROM enliterator_measures m
            WHERE m.tendable_type = v.tendable_type AND m.tendable_id = v.tendable_id
              AND m.name = 'condition' AND m.score = 1.0)
          ORDER BY COUNT(*) DESC
          LIMIT ?
        SQL
      )
      rows.map { |t, id, n, conf| { tendable_type: t, tendable_id: id, ok_visits: n.to_i, best_conf: conf&.to_f } }
    end

    def residue_count(min_visits: 2)
      residue(min_visits: min_visits, limit: 1_000_000).size
    end

    # ---- the survey queue ------------------------------------------------------

    # The next records to shelf-read: never-surveyed first (per model, fair
    # quota + one redistribution pass), then stalest computed_at. Returns
    # loaded records.
    #
    # fresh_only: true skips the stalest fallback — for run-to-completion
    # callers (the enliterator:survey rake): without it, once the frontier is
    # exhausted the stalest fallback feeds endless re-surveys and a "to
    # completion" loop NEVER terminates (caught live on HSDL: 408K survey
    # events over a 315K corpus before supervision pulled the cord). The
    # heartbeat phase keeps both (it's time-boxed; rolling re-surveys are its
    # job).
    def survey_due(limit:, models: tendable_models, fresh_only: false)
      return [] if models.empty? || limit <= 0
      picked = never_surveyed(limit, models)
      picked += stalest(limit - picked.size) if picked.size < limit && !fresh_only
      picked
    end

    def never_surveyed(limit, models)
      quota = [ limit / models.size, 1 ].max
      picked = []
      models.each do |model|
        break if picked.size >= limit
        picked += fetch_never_surveyed(model, [ quota, limit - picked.size ].min)
      end
      # One redistribution pass: spare capacity to models with more shelf.
      if picked.size < limit
        models.each do |model|
          break if picked.size >= limit
          extra = fetch_never_surveyed(model, limit - picked.size, skip: picked)
          picked += extra
        end
      end
      picked
    end

    def fetch_never_surveyed(model, n, skip: [])
      return [] if n <= 0
      pk   = "t.#{model.connection.quote_column_name(model.primary_key)}"
      type = ActiveRecord::Base.connection.quote(model.name)
      ids = ActiveRecord::Base.connection.select_values(
        ActiveRecord::Base.sanitize_sql_array([ <<~SQL, n + skip.size ])
          SELECT CAST(#{pk} AS TEXT)
          FROM #{model.quoted_table_name} t
          LEFT JOIN enliterator_measures m
            ON m.tendable_type = #{type} AND m.tendable_id = CAST(#{pk} AS TEXT) AND m.name = '#{ROLLUP}'
          WHERE m.id IS NULL
          ORDER BY #{pk}
          LIMIT ?
        SQL
      )
      skip_ids = skip.select { |r| r.class == model }.map { |r| r.public_send(model.primary_key).to_s }.to_set
      ids = ids.reject { |id| skip_ids.include?(id) }.first(n)
      model.where(model.primary_key => ids).to_a
    end

    def stalest(n)
      return [] if n <= 0
      Enliterator::Measure.where(name: ROLLUP).order(computed_at: :asc).limit(n)
                          .filter_map do |m|
        klass = m.tendable_type.safe_constantize
        klass && klass.find_by(klass.primary_key => m.tendable_id)
      end
    end

    # Registry ∪ visit log — same authority rule as the planner/Settings.
    def tendable_models
      names = Enliterator.tendable_models.map(&:name) |
              Enliterator::Visit.distinct.pluck(:tendable_type).compact
      names.sort.filter_map { |n| n.safe_constantize }
    end

    # ---- internals -------------------------------------------------------------

    def measure_row(record, name, score, signals, now)
      {
        tendable_type: record.class.name,
        tendable_id:   record.public_send(record.class.primary_key).to_s,
        name:          name,
        score:         score,
        signals:       signals,
        computed_at:   now,
        created_at:    now,
        updated_at:    now
      }
    end

    def log(msg)
      Enliterator.logger&.info("[enliterator:condition] #{msg}")
    rescue StandardError
      nil
    end
  end
end
