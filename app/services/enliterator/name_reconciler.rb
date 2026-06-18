module Enliterator
  # v0.45: the deterministic, HIGH-PRECISION name reconciler. It gathers the
  # person-name values of the configured name keys (advisor, authored_by, …) in a
  # context, clusters variant spellings of one person into an authority record
  # (status: auto), and HOLDS the cases it must not guess — never merging two
  # distinct people. The full governed loop (LLM/curator ratification of holds) is
  # deferred; this is the seed.
  #
  # Merges (auto): same first name + same surname, with compatible middles (one
  # bare, or a shared middle initial). Folds suffix/contractor/honorific/diacritic/
  # whitespace variants. The preferred (canonical) form is the cleanest, most
  # frequent, most complete variant.
  #
  # Holds (status: held — NOT applied): an ambiguous group (same first+last but two
  # different middle initials → possibly two people) and concatenated extraction
  # errors (a value containing two known surnames, e.g. "Robert Bach David Brannan").
  #
  # Idempotent: a re-run refreshes auto+held for the scope; human `ratified` rows
  # are preserved.
  class NameReconciler
    GENERATIONAL = %w[jr sr ii iii iv].freeze
    DEGREE_TAIL  = /,?\s*(ph\.?\s*d\.?|esq(?:uire)?\.?|m\.?\s*d\.?|j\.?\s*d\.?|ed\.?\s*d\.?)\s*\z/i

    def self.reconcile!(context: nil, keys: nil)
      new(context: context, keys: keys).reconcile!
    end

    def initialize(context: nil, keys: nil)
      @context = context
      @keys = Array(keys || Enliterator.configuration.name_authority_keys).map(&:to_s).reject(&:empty?)
    end

    def reconcile!
      return { skipped: "no name keys configured" } if @keys.empty?
      freq = gather
      auto, held = build(freq)
      persist!(auto, held)
      { auto: auto.size, held: held.size, values: freq.size }
    end

    private

    # { name_value => distinct-record count } across the name keys, in scope.
    def gather
      counts = Hash.new { |h, k| h[k] = Set.new }
      Enliterator::Claim.live.where(key: @keys, context_id: scope_ids).find_each do |c|
        flatten(c.value).each { |val| counts[val] << [ c.tendable_type, c.tendable_id ] }
      end
      counts.transform_values(&:size)
    end

    def scope_ids
      @context.respond_to?(:scope_ids) ? @context.scope_ids : [ @context&.id ]
    end

    def flatten(value)
      Array(value).flatten.select { |x| x.is_a?(String) }.map(&:strip).reject(&:empty?)
    end

    # "Robert L. Simeral (contractor)" → "robert l. simeral" (suffix/degree dropped,
    # diacritics folded, hyphen spacing tightened, whitespace collapsed, lowercased).
    def normalize(name)
      s = name.to_s.sub(/\s*\([^)]*\)\s*\z/, "").sub(DEGREE_TAIL, "")
      I18n.transliterate(s).gsub(/\s*-\s*/, "-").gsub(/\s+/, " ").strip.downcase
    end

    # [first, middle-initials, surname], or nil for an unparseable (single-token) name.
    def signature(norm)
      toks = norm.split(" ").reject { |t| GENERATIONAL.include?(t.delete(".")) }
      return nil if toks.size < 2
      [ toks.first, toks[1..-2].map { |t| t[0] }.join(" "), toks.last ]
    end

    def build(freq)
      parsed = freq.keys.filter_map { |v| (sig = signature(normalize(v))) && { value: v, sig: sig } }
      # surnames of any name advising ≥2 theses — used to spot concatenated values
      known = parsed.select { |p| freq[p[:value]] >= 2 }.map { |p| p[:sig][2] }.uniq

      held = []
      held_values = Set.new
      parsed.each do |p|
        # A value is concatenated if it embeds ≥2 known surnames — but EXCLUDE the
        # leading token (the person's own first name): many first names ("Thomas")
        # are also surnames elsewhere, and counting them held legit single names.
        hits = (normalize(p[:value]).split(" ").drop(1) & known).uniq
        next unless hits.size >= 2
        held << { canonical: p[:value], variants: [ p[:value] ] }
        held_values << p[:value]
      end

      auto = []
      parsed.reject { |p| held_values.include?(p[:value]) }
            .group_by { |p| [ p[:sig][0], p[:sig][2] ] }
            .each do |_first_last, members|
        values = members.map { |m| m[:value] }.uniq
        next if values.size < 2 # singleton → resolves to itself, no record needed
        mids = members.map { |m| m[:sig][1] }.reject(&:empty?).uniq
        if mids.size >= 2
          held << { canonical: values.first, variants: values } # ambiguous → don't guess
        else
          auto << { canonical: preferred(values, freq), variants: values }
        end
      end
      [ auto, held ]
    end

    # Cleanest (no parenthetical) → most frequent → most complete (token count).
    def preferred(values, freq)
      values.max_by { |v| [ v.include?("(") ? 0 : 1, freq[v], v.split.size ] }
    end

    def persist!(auto, held)
      NameAuthority.transaction do
        # Refresh derived rows; human-ratified authorities survive a re-run.
        NameAuthority.where(context_id: @context&.id, status: %w[auto held]).delete_all
        (auto.map { |c| c.merge(status: "auto") } + held.map { |c| c.merge(status: "held") }).each do |c|
          NameAuthority.create!(canonical: c[:canonical], variants: c[:variants].uniq,
                                kind: "person", context_id: @context&.id, status: c[:status])
        end
      end
    end
  end
end
