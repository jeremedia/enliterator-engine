require "rubygems/package"
require "zlib"

module Enliterator
  # v0.22: PORTABILITY — the enliteration is a movable asset.
  #
  # Everything the engine has learned (claims with their provenance chains,
  # visits, the ratified vocabulary, audits, embeddings) is spent inference
  # and irreplaceable curation; a fresh deployment should INHERIT it, not
  # re-buy it. Export writes ONE tar archive: manifest.json + one gzipped
  # PostgreSQL binary-COPY stream per table (binary COPY round-trips vector/
  # jsonb/tsvector exactly — the host's prod_clone precedent). Import loads
  # it verbatim — ids preserved, so every provenance chain survives — then
  # resets the sequences so new rows number after the imported history.
  #
  # The condition register (enliterator_measures) is EXCLUDED by default and
  # deliberately: it is free to re-derive (no LLM) and must describe the
  # TARGET's own files — a record's url_status on prod is not its url_status
  # on dev. Import says so. `measures: true` overrides for full clones.
  module Portability
    module_function

    # FK-safe load order. Self-references within a table (claim→superseded_by,
    # visit→escalated_from) are safe inside one COPY statement (non-deferrable
    # FK checks queue to statement end); CROSS-table order is what matters.
    TABLE_ORDER = %w[
      enliterator_contexts
      enliterator_heartbeats
      enliterator_visits
      enliterator_claims
      enliterator_audits
      enliterator_suggestions
      enliterator_proposed_terms
      enliterator_context_memberships
      enliterator_embeddings
      enliterator_treatments
      enliterator_measures
    ].freeze

    MANIFEST = "manifest.json"

    def export(path, measures: false)
      conn   = ActiveRecord::Base.connection
      tables = exportable_tables(conn, measures: measures)
      manifest = {
        "generated_at" => Time.current.iso8601,
        "host"         => (defined?(Rails) ? Rails.application.class.module_parent_name : nil),
        "tables"       => tables.each_with_object({}) do |t, h|
          h[t] = { "rows" => conn.select_value("SELECT COUNT(*) FROM #{t}").to_i,
                   "columns" => conn.columns(t).map(&:name) }
        end,
        "excluded"     => (measures ? [] : [ "enliterator_measures" ])
      }

      File.open(path, "wb") do |file|
        Gem::Package::TarWriter.new(file) do |tar|
          json = JSON.pretty_generate(manifest)
          tar.add_file_simple(MANIFEST, 0o644, json.bytesize) { |io| io.write(json) }
          tables.each do |t|
            log "export: #{t} (#{manifest['tables'][t]['rows']} rows)"
            payload = dump_table(conn, t)   # gzipped binary COPY, in memory
            tar.add_file_simple("#{t}.bin.gz", 0o644, payload.bytesize) { |io| io.write(payload) }
          end
        end
      end
      log "export: wrote #{path} (#{(File.size(path) / 1024.0 / 1024).round(1)} MB)"
      manifest
    end

    # Whole-archive import. `force:` truncates every enliterator table first
    # (ONE multi-table TRUNCATE, no CASCADE — cascading outside the engine's
    # tables must be impossible).
    def import(path, force: false)
      conn     = ActiveRecord::Base.connection
      manifest = read_manifest(path)
      assert_compatible!(conn, manifest)
      assert_importable!(conn, force: force)

      manifest["tables"].keys.sort_by { |t| [ TABLE_ORDER.index(t) || 99, t ] }.each do |t|
        import_table(path, t, skip_guard: true)
      end
      log "import: complete — #{summary_line(manifest)}"
      unless manifest["tables"].key?("enliterator_measures")
        log "import: the condition register was not imported (by design — it must describe " \
            "THIS host's files). Run `bin/rails enliterator:survey` for an honest local register."
      end
      log "import: note — the first heartbeat here may carry a source_change wave (this host's " \
          "records may genuinely differ from the ones the imported visits read)."
      manifest
    end

    # One table — the maintenance-task entry point (the task iterates the
    # manifest's tables so its UI shows per-table progress). The empty-target
    # guard is the CALLER's job when importing piecemeal (skip_guard).
    def import_table(path, table, skip_guard: false)
      conn = ActiveRecord::Base.connection
      unless skip_guard
        manifest = read_manifest(path)
        assert_compatible!(conn, manifest)
      end
      rows = 0
      each_entry(path) do |entry|
        next unless entry.full_name == "#{table}.bin.gz"
        gz = Zlib::GzipReader.new(StringIO.new(entry.read))
        rc = conn.raw_connection
        rc.copy_data("COPY #{conn.quote_table_name(table)} FROM STDIN (FORMAT binary)") do
          while (chunk = gz.read(65_536))
            rc.put_copy_data(chunk)
          end
        end
        rows = conn.select_value("SELECT COUNT(*) FROM #{table}").to_i
      end
      reset_sequence(conn, table)
      log "import: #{table} → #{rows} rows"
      rows
    end

    def read_manifest(path)
      manifest = nil
      each_entry(path) do |entry|
        manifest = JSON.parse(entry.read) if entry.full_name == MANIFEST
        break if manifest
      end
      raise ArgumentError, "#{path}: no #{MANIFEST} found — not an enliteration archive" unless manifest
      manifest
    end

    # ---- guards ------------------------------------------------------------

    # The archive's column lists must MATCH the target's exactly — binary COPY
    # is positional, and a schema-version skew must abort by name, never load
    # crooked data.
    def assert_compatible!(conn, manifest)
      manifest["tables"].each do |t, info|
        unless conn.table_exists?(t)
          raise ArgumentError, "archive has #{t} but this database does not — " \
                               "engine version skew (run the engine migrations first)"
        end
        target = conn.columns(t).map(&:name)
        next if target == info["columns"]
        raise ArgumentError, "#{t}: column mismatch between archive and this database " \
                             "(archive: #{info['columns'].join(',')} | here: #{target.join(',')}) — " \
                             "engine version skew"
      end
    end

    def assert_importable!(conn, force: false)
      counts = engine_tables(conn).each_with_object({}) do |t, h|
        n = conn.select_value("SELECT COUNT(*) FROM #{t}").to_i
        h[t] = n if n.positive?
      end
      if counts.any? && !force
        raise ArgumentError, "target is not empty (#{counts.map { |t, n| "#{t}: #{n}" }.join(', ')}) — " \
                             "pass force to truncate and replace"
      end
      if counts.any?
        log "import: FORCE — truncating #{counts.keys.size} non-empty enliterator table(s)"
        conn.execute("TRUNCATE #{engine_tables(conn).join(', ')} RESTART IDENTITY")
      end
    end

    # ---- internals ---------------------------------------------------------

    def exportable_tables(conn, measures:)
      tables = engine_tables(conn)
      tables -= [ "enliterator_measures" ] unless measures
      # Known order first; any future engine table not yet listed still ships
      # (appended, logged) rather than silently dropped.
      (TABLE_ORDER & tables) + (tables - TABLE_ORDER).sort.each { |t| log "export: #{t} not in TABLE_ORDER — appended last" }
    end

    def engine_tables(conn)
      conn.tables.grep(/\Aenliterator_/).sort
    end

    def dump_table(conn, table)
      out = StringIO.new
      gz  = Zlib::GzipWriter.new(out)
      rc  = conn.raw_connection
      rc.copy_data("COPY #{conn.quote_table_name(table)} TO STDOUT (FORMAT binary)") do
        while (chunk = rc.get_copy_data)
          gz.write(chunk)
        end
      end
      gz.finish
      out.string
    end

    def each_entry(path)
      File.open(path, "rb") do |file|
        Gem::Package::TarReader.new(file) do |tar|
          tar.each { |entry| yield entry }
        end
      end
    end

    def reset_sequence(conn, table)
      seq = conn.select_value("SELECT pg_get_serial_sequence('#{table}', 'id')")
      return unless seq
      conn.execute("SELECT setval('#{seq}', COALESCE((SELECT MAX(id) FROM #{table}), 0) + 1, false)")
    end

    def summary_line(manifest)
      manifest["tables"].map { |t, i| "#{t.sub('enliterator_', '')} #{i['rows']}" }.join(" · ")
    end

    def log(msg)
      Enliterator.logger&.info("[enliterator:portability] #{msg}")
    end
  end
end
