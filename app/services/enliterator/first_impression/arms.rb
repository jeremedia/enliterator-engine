module Enliterator
  module FirstImpression
    # The reading conditions under test. Each arm is a CONTEXT string handed to the
    # model; the questions are identical across arms. The confound the whole
    # diagnostic rests on: the non-`fulltext` arms all carry the SAME surrogate text,
    # so any coverage/reliability difference is presentation (the enliteration), not
    # information the surrogate withheld. `manual` adds only the enliteration; `map`
    # adds only the record's own bibliographic access points.
    #
    # Host-generic core = no_map / map / manual. `fulltext` is opt-in: it appears only
    # when the host supplies a fuller source via config.first_impression_full_text —
    # many hosts' surrogate already IS the full text, so there is nothing to add.
    module Arms
      CORE = %w[no_map map manual].freeze

      # Bibliographic claim keys a catalog record would carry (the `map` arm). These
      # are access points, NOT the deep findings the enliteration adds.
      BIB_KEYS = %w[authored_by advisor keywords].freeze

      # @param record   a Tendable host record (responds to #enliterator_text)
      # @param claims    the record's live claims (each responds to #key, #value)
      # @param full_text [String, nil] a fuller source for the optional `fulltext` arm
      # @return [Hash{String=>String}] arm name => context string
      def self.build(record, claims:, full_text: nil)
        surrogate = record.enliterator_text.to_s
        out = {
          "no_map" => no_map(surrogate),
          "map"    => map(surrogate, record, claims),
          "manual" => manual(surrogate, claims)
        }
        out["fulltext"] = fulltext(full_text) if full_text.to_s.strip.length.positive?
        out
      end

      def self.names(full_text: nil)
        full_text.to_s.strip.empty? ? CORE : CORE + %w[fulltext]
      end

      def self.no_map(surrogate)
        "SOURCE (catalog abstract):\n\n#{surrogate}"
      end

      def self.map(surrogate, record, claims)
        "#{catalog(record, claims)}\n\nSOURCE (catalog abstract):\n\n#{surrogate}"
      end

      def self.manual(surrogate, claims)
        "SOURCE (catalog abstract):\n\n#{surrogate}\n\n#{enliteration(claims)}"
      end

      def self.fulltext(full_text)
        "SOURCE (opening portion of the full source, truncated to fit):\n\n#{full_text}"
      end

      # The `map` arm's catalog: the record's title (when it has one) plus its
      # bibliographic claims — the access points a catalog record holds, without the
      # deep findings.
      def self.catalog(record, claims)
        lines = [ "CATALOG RECORD" ]
        title = record.respond_to?(:title) ? record.title.to_s : ""
        lines << "Title: #{title}" if title.strip.length.positive?
        claims.select { |c| BIB_KEYS.include?(c.key.to_s) }.each do |c|
          lines << "#{c.key.to_s.tr('_', ' ').capitalize}: #{Enliterator::Trajectory.render(c.value)}"
        end
        lines.join("\n")
      end

      # The `manual` arm's enliteration block — the engine's structured reading,
      # rendered "- key: value" (the same shape as Trajectory::Judge#render_state),
      # with each claim's audit verdict when one exists.
      def self.enliteration(claims)
        head = [
          "VERIFIED ENLITERATION — the engine's structured reading of the full record,",
          "distilled into claims, each with a confidence and (when audited) an independent",
          "verdict checked against the full source. These capture detail the abstract omits.",
          ""
        ]
        rows = claims.map do |c|
          verdict = c.respond_to?(:audit_verdict) && c.audit_verdict ? "; audit: #{c.audit_verdict}" : ""
          conf = c.respond_to?(:confidence) && c.confidence ? "; confidence #{c.confidence}" : ""
          "- #{c.key}: #{Enliterator::Trajectory.render(c.value)}#{conf}#{verdict}"
        end
        (head + rows).join("\n")
      end
    end
  end
end
