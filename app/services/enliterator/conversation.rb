module Enliterator
  # Converse with an enliteration's top-level potential — the HYBRID grounding:
  # every turn opens from the collection SELF-PORTRAIT (Synopsis — what the
  # collection knows about itself) AND drills into the specific tended records most
  # relevant to the question (embedding retrieval -> their live claims). The model
  # answers in free-form prose grounded ONLY in that assembled context; it never
  # writes claims. This is the chapter's "the collection looked back," made
  # interactive.
  #
  #   conv = Enliterator::Conversation.new
  #   prov = conv.reply(question: "What does this collection know about itself?",
  #                     stream: true) { |delta| sse(delta) }
  #   prov[:records]  # => the retrieved records that grounded the answer
  #
  # Token budget is bounded by constructor knobs (synopsis caps + retrieve_k +
  # history_cap + per-record claim cap), so prompt size is independent of corpus size.
  class Conversation
    CLAIM_CAP = 12       # max live claims injected per retrieved record
    SNIPPET   = 280      # chars of record text used as an identifying snippet
    VALUE_MAX = 200      # chars per claim value in the prompt

    def initialize(llm: nil, embedder: Enliterator.embedder, synopsis: nil,
                   retrieve_k: 5, history_cap: 6, context: nil)
      @llm         = llm
      @embedder    = embedder
      @synopsis    = synopsis
      @retrieve_k  = retrieve_k
      @history_cap = history_cap
      # v0.13: converse THROUGH a context — the self-portrait, retrieval pool,
      # and claim reads are all scoped to it. nil = the whole collection (root).
      @context     = context
    end

    # Answer a question. When +stream+ is true and a block is given, the block is
    # yielded incremental text deltas. Returns a provenance hash:
    #   { answer:, records: [{type,id,label,distance}], tier:, degraded: }
    def reply(question:, history: [], stream: nil, &block)
      adapter  = resolve_llm
      degraded = null_degraded(adapter)

      records  = retrieve(question)
      messages = build_messages(question, history, records)

      answer = adapter.converse(
        messages: messages,
        tags:     [ "enliterator", "conversation" ],
        stream:   !!stream,
        &block
      )

      {
        answer:   answer,
        records:  records.map { |r| r.slice(:type, :id, :label, :distance) },
        tier:     adapter.model_id,
        degraded: degraded
      }
    end

    # The self-portrait used to ground the conversation (memoized per instance).
    def synopsis
      @synopsis ||= Enliterator::Synopsis.build(context: @context)
    end

    private

    # Injected llm wins (specs). Else the configured conversation tier, else the
    # staffing ladder's TOP tier (conversation wants capability), else "quality".
    def resolve_llm
      return @llm if @llm
      tier = Enliterator.configuration.conversation_tier ||
             Enliterator.staffing.ladder.last ||
             "quality"
      Enliterator.llm(tier: tier)
    end

    # A SOFT signal — not a raise. Conversation writes no rows, so the v0.5
    # phantom-Visit hazard doesn't apply; we surface the degraded state instead.
    def null_degraded(adapter)
      return nil unless adapter.is_a?(Enliterator::Adapters::LLM::Null)
      return nil if Enliterator.configuration.allow_null_llm
      Enliterator.logger&.warn(
        "[enliterator] conversation resolved the Null adapter (no gateway key); " \
        "returning an inert answer. Set ENLITERATOR_LLM_KEY to converse."
      )
      "null-llm"
    end

    # The drill-down: embed the question, find nearest tended records, load each
    # one's live claims. Mirrors Visitor#nearest_neighbors + literacy_state —
    # including the v0.13 scoping: within a context the retrieval pool is the
    # context's MEMBERS and the claims read up its path; root stays corpus-wide.
    def retrieve(question)
      vector = @embedder.embed(question)
      return [] if vector.nil?

      pool = Enliterator::Embedding.where(kind: "primary").in_context(@context)

      pool.nearest_neighbors(:embedding, vector, distance: "cosine").first(@retrieve_k).filter_map do |emb|
        rec = emb.embeddable
        next if rec.nil?
        claims = rec.enliterator_claims.live
        claims = claims.where(context_id: @context.scope_ids) if @context
        {
          type:     rec.class.name,
          id:       rec.id,
          label:    (rec.try(:title) || rec.try(:name) || "#{rec.class.name}/#{rec.id}").to_s,
          snippet:  snippet_for(rec),
          distance: (emb.respond_to?(:neighbor_distance) ? emb.neighbor_distance : nil),
          claims:   claims.limit(CLAIM_CAP).map(&:to_state)
        }
      end
    end

    def snippet_for(record)
      return nil unless record.respond_to?(:enliterator_text)
      record.enliterator_text.to_s.gsub(/\s+/, " ").strip[0, SNIPPET]
    rescue StandardError
      nil
    end

    def build_messages(question, history, records)
      msgs = [ { role: "system", content: system_prompt } ]
      Array(history).last(@history_cap).each do |turn|
        role    = (turn[:role] || turn["role"]).to_s
        content = (turn[:content] || turn["content"]).to_s
        next if role.empty? || content.empty?
        msgs << { role: role, content: content }
      end
      msgs << { role: "user", content: user_prompt(question, records) }
      msgs
    end

    def system_prompt
      <<~SYS.strip
        You ARE the enliteration of a collection — you speak about the collection as a
        whole and about its individual records, grounded ONLY in the SELF-PORTRAIT and
        the RETRIEVED RECORDS provided. Do not invent facts beyond them. If the
        retrieved records do not cover the question, say so plainly rather than guessing.

        Cite records by a HUMAN-READABLE label — the title, optionally followed by the
        author and year shown for that record — never by a raw internal id. Do NOT print
        record ids (e.g. "Type/id" or UUIDs) in your answer unless the user explicitly
        asks for them. After first mention you may shorten a long title when it stays
        unambiguous. If a record has no usable title, say so rather than inventing one.

        #{Enliterator::Synopsis.to_prompt(synopsis)}
      SYS
    end

    def user_prompt(question, records)
      retrieved =
        if records.empty?
          "(no records matched this question)"
        else
          records.map { |r| record_block(r) }.join("\n\n")
        end

      <<~USER.strip
        Question: #{question}

        RETRIEVED RECORDS (most relevant first):
        #{retrieved}
      USER
    end

    def record_block(r)
      claim_lines = Array(r[:claims]).map { |c| "    #{c[:key]}: #{render_value(c[:value])}" }.join("\n")
      # Lead with the human-readable citation (title + author + year), NOT the raw
      # id — the model cites what it's handed. The id travels separately in the
      # provenance channel (the source chips), which carry the working links.
      [ "- #{citation_label(r)}",
        ("  #{r[:snippet]}" if r[:snippet].present?),
        claim_lines.presence ].compact.join("\n")
    end

    # "Title" — by Author (Year). Author/year are pulled from the record's own
    # claims; the collection's metadata is uneven, so each part degrades gracefully.
    def citation_label(r)
      title  = r[:label].presence || "#{r[:type]}/#{r[:id]}"
      author = display_author(claim_value(r[:claims], "authored_by"))
      year   = claim_value(r[:claims], "publication_year")
      out = %("#{title}")
      out += " — by #{author}" if author.present?
      out += " (#{year})" if year.to_s.present?
      out
    end

    def claim_value(claims, key)
      c = Array(claims).find { |x| (x[:key] || x["key"]).to_s == key }
      c && (c[:value] || c["value"])
    end

    def display_author(value)
      case value
      when Array  then value.compact.join(", ")
      when String then value
      else value
      end
    end

    def render_value(value)
      s = value.is_a?(String) ? value : value.to_json
      s.length > VALUE_MAX ? "#{s[0, VALUE_MAX]}…" : s
    end
  end
end
