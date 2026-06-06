module Enliterator
  module Tending
    # THE compounding contract (literacy rung 5).
    #
    # One Visitor instance performs one tending pass over one record along one
    # stream. It reads the record's accumulated understanding (prior claims +
    # recent visits + facets) plus its corpus neighbors, hands all of that to the
    # LLM, and reconciles the model's proposed claims against what already exists.
    # Because each visit conditions the next, understanding compounds.
    #
    #   Enliterator::Tending::Visitor.new(record, stream: "summary").call
    #
    class Visitor
      # Bump when the prompt contract or reconcile semantics change in a way that
      # should invalidate cached interpretation. Stamped onto every Visit.
      PROMPT_VERSION = "v0.1".freeze

      attr_reader :tendable, :stream, :llm, :embedder

      def initialize(tendable, stream:, llm: Enliterator.llm, embedder: Enliterator.embedder)
        @tendable = tendable
        @stream   = stream.to_s
        @llm      = llm
        @embedder = embedder
      end

      # Run the full visit lifecycle. Returns the finalized Visit.
      def call
        started = Time.current
        visit = tendable.enliterator_visits.create!(
          stream:         stream,
          status:         "running",
          model:          llm.model_id,
          prompt_version: PROMPT_VERSION,
          started_at:     started
        )

        begin
          # 2. Prior understanding — this is what makes it compound.
          state = tendable.literacy_state(stream: stream)

          # 3. Corpus context via embeddings (gracefully empty if not embedded yet).
          neighbors = nearest_neighbors(tendable, limit: 5)

          # 4. Ask the model to interpret the record in light of all of the above.
          response = llm.tend(
            text:      tendable.enliterator_text,
            stream:    stream,
            state:     state,
            neighbors: neighbors
          )
          parsed = response.parsed || {}

          # 5. Reconcile proposed claims against the existing live claim store.
          recon = reconcile!(parsed["claims"], visit)

          # 6. Finalize the visit with everything it read and produced.
          finished     = Time.current
          duration_ms  = ((finished - started) * 1000).round
          input_refs   = {
            prior_visit_ids: prior_visit_ids(visit),
            neighbor_ids:    neighbors.map { |n| neighbor_id(n) }.compact,
            claim_keys:      state[:claims].map { |c| c[:key] }.compact
          }

          visit.update!(
            status:         "succeeded",
            raw_response:   response.respond_to?(:raw) ? (response.raw || {}) : {},
            reconciliation: recon,
            confidence:     parsed["confidence"],
            input_refs:     input_refs,
            tokens:         response.respond_to?(:tokens) ? (response.tokens || {}) : {},
            duration_ms:    duration_ms,
            finished_at:    finished
          )

          # 7. Recompute quality facets now that claims/visits may have changed.
          Enliterator::Facets.recompute!(tendable)

          visit
        rescue => e
          # 9. Record the failure on the immutable history and re-raise.
          visit.update_columns(
            status:      "failed",
            error:       e.message,
            finished_at: Time.current,
            updated_at:  Time.current
          )
          raise
        end
      end

      # The mem0-style ADD/UPDATE/DELETE/NOOP reconcile contract.
      #
      # `proposed` is an array of `{ "key", "value", "confidence", "op" }`.
      # op ∈ ADD | UPDATE | DELETE | NOOP. When op is absent it defaults to UPDATE
      # if a live claim already exists for the key, otherwise ADD.
      #
      # Returns `{added:[keys], updated:[keys], deleted:[keys], noop:[keys]}`.
      def reconcile!(proposed, visit)
        recon = { added: [], updated: [], deleted: [], noop: [] }
        return recon if proposed.blank?

        proposed.each do |raw|
          key        = raw["key"] || raw[:key]
          next if key.blank?

          value      = raw.key?("value") ? raw["value"] : raw[:value]
          confidence = raw["confidence"] || raw[:confidence]
          existing   = live_claim_for(key)
          op         = normalize_op(raw["op"] || raw[:op], existing)

          case op
          when "ADD"
            create_claim(key: key, value: value, confidence: confidence, visit: visit)
            recon[:added] << key

          when "UPDATE"
            if existing.nil?
              # Nothing to update — treat as an ADD so the claim isn't lost.
              create_claim(key: key, value: value, confidence: confidence, visit: visit)
              recon[:added] << key
            elsif existing.locked
              # Curator anchor — never auto-supersede.
              recon[:noop] << key
            else
              fresh = create_claim(
                key:         key,
                value:       value,
                confidence:  confidence,
                visit:       visit,
                derived_from: [ { "type" => "claim", "id" => existing.id } ]
              )
              existing.supersede!(fresh)
              recon[:updated] << key
            end

          when "DELETE"
            if existing.nil?
              recon[:noop] << key
            elsif existing.locked
              recon[:noop] << key
            else
              # Tombstone: superseded with no replacement.
              existing.update!(status: "superseded")
              recon[:deleted] << key
            end

          else # NOOP
            recon[:noop] << key
          end
        end

        recon
      end

      # The tendable's "primary" embedding's nearest corpus neighbors (excluding
      # self). Returns Embedding rows ordered nearest-first, or [] if the record
      # has no primary embedding yet.
      def nearest_neighbors(tendable, limit:)
        own = tendable.enliterator_embeddings.find_by(kind: "primary")
        return [] if own.nil? || own.embedding.nil?

        # Fetch one extra so we can drop self without falling short.
        Enliterator::Embedding
          .nearest_to(own.embedding, kind: "primary", limit: limit + 1)
          .reject { |e| e.id == own.id }
          .first(limit)
      end

      private

      # Resolve the proposed op, defaulting based on whether a live claim exists.
      def normalize_op(op, existing)
        normalized = op.to_s.strip.upcase
        return normalized if %w[ADD UPDATE DELETE NOOP].include?(normalized)

        existing ? "UPDATE" : "ADD"
      end

      def live_claim_for(key)
        tendable.enliterator_claims.live.find_by(key: key)
      end

      # The prior visits this pass read for context (same stream, the 5 most
      # recent that precede the visit being finalized — matching literacy_state).
      def prior_visit_ids(visit)
        tendable.enliterator_visits
          .where(stream: stream)
          .where.not(id: visit.id)
          .order(created_at: :desc)
          .limit(5)
          .pluck(:id)
      end

      def create_claim(key:, value:, confidence:, visit:, derived_from: [])
        tendable.enliterator_claims.create!(
          key:          key,
          value:        value,
          confidence:   confidence,
          status:       "draft",
          visit:        visit,
          attributed_to: llm.model_id,
          derived_from: derived_from
        )
      end

      # An Embedding row's stable identity for input_refs provenance.
      def neighbor_id(neighbor)
        neighbor.respond_to?(:id) ? neighbor.id : nil
      end
    end
  end
end
