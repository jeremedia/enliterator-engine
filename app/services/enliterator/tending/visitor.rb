module Enliterator
  module Tending
    # THE compounding contract (literacy rung 5), now WITH staffing & escalation.
    #
    # One Visitor instance performs one tending of one record along one stream. It
    # reads the record's accumulated understanding (prior claims + recent visits +
    # facets) plus its corpus neighbors, hands all of that to a language model, and
    # reconciles the model's proposed claims against what already exists. Because
    # each visit conditions the next, understanding compounds.
    #
    #   Enliterator::Tending::Visitor.new(record, stream: "summary").call
    #
    # TWO paths share this class:
    #
    # * BACK-COMPAT (v0.1): an explicit `llm:` is injected. One visit at that exact
    #   adapter, reconciled and written directly — no staffing, no escalation. The
    #   v0.1 spec drives this path and must stay green.
    #
    # * STAFFING (v0.2): no `llm:` is injected. The staffing policy picks the tier
    #   for the stream, clamps the ladder by the record's constraints, runs a visit
    #   at that tier, and — when the result is low-confidence or self-flagged —
    #   ESCALATES up the ladder (bounded by max_promotions), handing the junior
    #   tier's proposed claims to the senior for review. Only the FINAL tier's visit
    #   reconciles and writes claims; junior visits are recorded as provenance only
    #   (applied: false). A verify_floor gates which tier may mint `verified` claims.
    class Visitor
      # Bump when the prompt contract or reconcile semantics change in a way that
      # should invalidate cached interpretation. Stamped onto every Visit.
      PROMPT_VERSION = "v0.1".freeze

      attr_reader :tendable, :stream, :embedder

      def initialize(tendable, stream:, llm: nil, embedder: Enliterator.embedder)
        @tendable     = tendable
        @stream       = stream.to_s
        @injected_llm = llm           # non-nil => v0.1 back-compat path
        @embedder     = embedder
      end

      # The LLM adapter for the back-compat path (kept as a public reader so
      # callers/specs that referenced #llm in v0.1 still work). In the staffing
      # path this is nil; the policy resolves a per-tier adapter instead.
      def llm
        @injected_llm
      end

      # Run the full tending. Returns the finalized (authoritative) Visit.
      def call
        if @injected_llm
          call_back_compat
        else
          call_with_staffing
        end
      end

      # ---- BACK-COMPAT (v0.1): single visit, direct write -------------------

      # Exactly the v0.1 lifecycle. One visit at the injected adapter, reconcile
      # immediately, claims minted "draft" with attributed_to = model_id. The new
      # `tier`/`applied` columns are stamped as harmless metadata (tier = the
      # adapter's model_id, applied: true) — no v0.1 assertion depends on them.
      def call_back_compat
        adapter = @injected_llm
        started = Time.current
        visit = tendable.enliterator_visits.create!(
          stream:         stream,
          status:         "running",
          model:          adapter.model_id,
          tier:           adapter.model_id,
          applied:        true,
          prompt_version: PROMPT_VERSION,
          started_at:     started
        )

        begin
          state     = tendable.literacy_state(stream: stream)
          neighbors = nearest_neighbors(tendable, limit: 5)

          response = adapter.tend(
            text:      tendable.enliterator_text(stream: stream),
            stream:    stream,
            state:     state,
            neighbors: neighbors
          )
          parsed = response.parsed || {}

          recon = reconcile!(
            parsed["claims"], visit,
            attributed_to: adapter.model_id,
            tier:          nil,            # v0.1 claims carry no tier
            may_verify:    false           # v0.1 never mints verified
          )

          finalize_succeeded!(
            visit, response, recon, parsed, started,
            neighbors: neighbors, state: state
          )

          Enliterator::Facets.recompute!(tendable)
          visit
        rescue => e
          fail_visit!(visit, e)
          raise
        end
      end

      # ---- STAFFING (v0.2): tier routing + bounded escalation --------------

      def call_with_staffing
        policy  = Enliterator.staffing
        allowed = policy.allowed_tiers(tendable, stream)

        # v0.3 output contract for this stream (the controlled key vocabulary), or
        # nil when the stream is unconstrained (declared via #assign / not at all).
        # nil ⇒ open keys + no suggestions ⇒ byte-identical to v0.2.
        # v0.9: the EFFECTIVE contract — code keys + any curator-approved keys — so
        # an approved key is emitted as a claim, not re-proposed. == keys_for when
        # nothing is approved.
        contract = Enliterator::Vocabulary.for(stream)

        # v0.5: keys this stream MUST yield a non-blank claim for (subset of contract),
        # or nil. An unmet required key forces escalation regardless of confidence and
        # bars `verified` at the top tier. nil ⇒ byte-identical to v0.3/v0.4.
        required = policy.required_keys(stream)

        # No tier may legally run this record (e.g. on-prem-only with no on-prem
        # ladder). Record a failed visit and surface the misconfiguration.
        if allowed.empty?
          raise Enliterator::ConfigurationError,
                "No staffing tier may run #{tendable.class.name}/#{tendable.id} " \
                "on stream #{stream.inspect} (allowed ladder is empty after constraints)."
        end

        start_tier = clamp_start_tier(policy.tier_for(stream), allowed)
        # The remaining climb available to this record, in ladder order.
        climb      = ladder_climb(start_tier, allowed)

        prior_visit   = nil          # the junior visit we escalated from (provenance)
        proposed      = nil          # the junior's proposed claims handed up for review
        step          = 0
        current_tier  = start_tier
        current_visit = nil
        current_parsed = nil

        loop do
          current_visit, current_parsed = run_tier_visit(
            tier:              current_tier,
            step:              step,
            escalated_from:    prior_visit,
            proposed_by_lower: proposed,
            contract:          contract,
            required:          required
          )

          # v0.5: a required key that came back empty forces escalation even when the
          # model reported high confidence (the confidently-empty author case).
          required_unmet = required.present? && required_keys_unmet?(required, current_parsed["claims"])

          # Decide whether to climb: low confidence / self-flag / unmet required key,
          # a higher tier exists in the allowed ladder, and we are under the bound.
          next_tier = climb[step + 1]
          break unless next_tier
          break unless step < policy.max_promotions
          break unless policy.escalate?(current_visit) || required_unmet

          # Promote: this junior visit is provenance only — its reconciliation is
          # NOT applied. Carry its proposed claims up for the senior to review.
          mark_superseded!(current_visit)
          prior_visit  = current_visit
          proposed     = current_parsed["claims"]
          step        += 1
          current_tier = next_tier
        end

        # Recompute unmet against the FINAL tier's claims. If still unmet at the top
        # of the climb, the visit finalizes succeeded but mints no verified and is
        # flagged (reconciliation["required_unmet"] = true).
        final_unmet = required.present? && required_keys_unmet?(required, current_parsed["claims"])

        # Only the FINAL tier's visit reconciles and writes claims. It is also the
        # only place v0.3 suggestions are persisted (junior visits never persist).
        finalize_final_visit!(current_visit, current_parsed, current_tier, policy,
                              contract: contract, required_unmet: final_unmet)
        Enliterator::Facets.recompute!(tendable)
        current_visit
      end

      # The mem0-style ADD/UPDATE/DELETE/NOOP reconcile contract.
      #
      # `proposed` is an array of `{ "key", "value", "confidence", "op" }`.
      # op ∈ ADD | UPDATE | DELETE | NOOP. When op is absent it defaults to UPDATE
      # if a live claim already exists for the key, otherwise ADD.
      #
      # `attributed_to` / `tier` are stamped on created claims (provenance). When
      # `may_verify` is true AND the model asserted high confidence for a claim,
      # that claim is minted `verified`; otherwise `draft`.
      #
      # Returns `{added:[keys], updated:[keys], deleted:[keys], noop:[keys]}`.
      def reconcile!(proposed, visit, attributed_to:, tier:, may_verify:)
        recon = { added: [], updated: [], deleted: [], noop: [] }
        return recon if proposed.blank?

        proposed.each do |raw|
          key = raw["key"] || raw[:key]
          next if key.blank?

          value      = raw.key?("value") ? raw["value"] : raw[:value]
          confidence = raw["confidence"] || raw[:confidence]
          existing   = live_claim_for(key)
          op         = normalize_op(raw["op"] || raw[:op], existing)
          status     = claim_status(may_verify: may_verify, confidence: confidence, raw: raw)

          case op
          when "ADD"
            create_claim(
              key: key, value: value, confidence: confidence, visit: visit,
              attributed_to: attributed_to, tier: tier, status: status
            )
            recon[:added] << key

          when "UPDATE"
            if existing.nil?
              # Nothing to update — treat as an ADD so the claim isn't lost.
              create_claim(
                key: key, value: value, confidence: confidence, visit: visit,
                attributed_to: attributed_to, tier: tier, status: status
              )
              recon[:added] << key
            elsif existing.locked
              # Curator anchor — never auto-supersede.
              recon[:noop] << key
            else
              fresh = create_claim(
                key:           key,
                value:         value,
                confidence:    confidence,
                visit:         visit,
                attributed_to: attributed_to,
                tier:          tier,
                status:        status,
                derived_from:  [ { "type" => "claim", "id" => existing.id } ]
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

      # The tendable's "primary" embedding's nearest corpus NEIGHBORS (excluding
      # self), resolved to the embeddable RECORDS so the model can actually read
      # and reference them (title/summary) — the chapter's "corpus meeting the
      # record". Returns records ordered nearest-first, or [] if this record has no
      # primary embedding yet. (v0.4: previously returned bare Embedding rows, which
      # carried no title/text — the model couldn't connect to records it couldn't see.)
      def nearest_neighbors(tendable, limit:)
        own = tendable.enliterator_embeddings.find_by(kind: "primary")
        return [] if own.nil? || own.embedding.nil?

        # Fetch one extra so we can drop self without falling short.
        Enliterator::Embedding
          .nearest_to(own.embedding, kind: "primary", limit: limit + 1)
          .reject { |e| e.id == own.id }
          .first(limit)
          .map(&:embeddable)
          .compact
      end

      private

      # ---- staffing helpers ------------------------------------------------

      # Run one tending at a tier, recording the Visit (tier, tokens, raw,
      # escalation linkage). Does NOT reconcile — the loop decides which visit
      # writes. Returns [visit, parsed].
      def run_tier_visit(tier:, step:, escalated_from:, proposed_by_lower:, contract: nil, required: nil)
        adapter = Enliterator.llm(tier: tier)
        log_event("resolve", tier: tier, adapter: adapter.class.name, model_id: adapter.model_id,
                             stream: stream, tendable: tendable_ref, step: step)
        refuse_null!(adapter, tier)
        started = Time.current

        visit = tendable.enliterator_visits.create!(
          stream:           stream,
          status:           "running",
          model:            adapter.model_id,
          tier:             tier.to_s,
          applied:          true,                 # provisional; flipped to false if superseded
          escalation_step:  step,
          escalated_from:   escalated_from,
          prompt_version:   PROMPT_VERSION,
          started_at:       started
        )

        begin
          state = tendable.literacy_state(stream: stream)
          # Senior REVIEWS junior: hand the lower tier's draft claims up so the
          # prompt presents them explicitly (Base#build_user pulls this key out).
          state = state.merge("proposed_by_lower_tier" => proposed_by_lower) if proposed_by_lower

          neighbors = nearest_neighbors(tendable, limit: 5)
          tags      = spend_tags(tier: tier, step: step)

          response = tend_with_optional_kwargs(
            adapter,
            text:      tendable.enliterator_text(stream: stream),
            stream:    stream,
            state:     state,
            neighbors: neighbors,
            tags:      tags,
            contract:  contract,
            required:  required
          )
          parsed = response.parsed || {}

          # Stamp the per-visit record. raw_response carries the model's self-
          # escalate flag (if any) so Policy#escalate? can read it back.
          finished    = Time.current
          duration_ms = ((finished - started) * 1000).round
          visit.update!(
            status:         "succeeded",
            raw_response:   raw_with_escalate(response, parsed),
            confidence:     parsed["confidence"],
            input_refs:     input_refs_for(visit, neighbors: neighbors, state: state),
            tokens:         tokens_of(response),
            duration_ms:    duration_ms,
            finished_at:    finished
          )
          log_event("visit", visit_id: visit.id, stream: stream, tier: tier, step: step,
                             confidence: visit.confidence, applied: visit.applied,
                             tokens: token_total(visit.tokens), duration_ms: duration_ms,
                             status: "succeeded")

          [ visit, parsed ]
        rescue => e
          fail_visit!(visit, e)
          raise
        end
      end

      # Apply the final tier's reconciliation and stamp the visit's reconciliation
      # summary. This is the ONLY place claims are written in the staffing path —
      # and the ONLY place v0.3 suggestions are persisted (junior visits never do).
      #
      # CONTRACT (v0.3): when the stream has an output contract, reconcile ONLY the
      # claims whose key is in the allowed vocabulary; off-list keys are dropped (the
      # schema enum should already prevent them — this is the safety net). When no
      # contract, reconcile ALL proposed claims (v0.2, byte-identical).
      def finalize_final_visit!(visit, parsed, tier, policy, contract: nil, required_unmet: false)
        # v0.5: a still-unmet required key at the top of the climb bars `verified` —
        # we never mint a verified claim for a stream that failed to produce a
        # mandated fact. When required_unmet is false this is unchanged from v0.4.
        may_verify = policy.may_verify?(tier) && !required_unmet
        claims     = contract.nil? ? parsed["claims"] : filter_claims_to_contract(parsed["claims"], contract)

        recon = reconcile!(
          claims, visit,
          attributed_to: "#{tier}:#{visit.model}",
          tier:          tier.to_s,
          may_verify:    may_verify
        )
        # Flag ONLY when truly unmet, so the contract-absent / required-absent path
        # writes the exact same reconciliation hash as v0.4 (specs assert it).
        recon[:required_unmet] = true if required_unmet
        visit.update!(reconciliation: recon, applied: true)
        log_event("reconcile", visit_id: visit.id, stream: stream, tier: tier,
                              ops: recon_ops(recon), required_unmet: (required_unmet || nil))

        # Persist the model's proposed key additions for governance. No-op when the
        # model emitted no suggestions (so the contract-absent path never touches the
        # suggestions table).
        persist_suggestions!(parsed["suggestions"], visit: visit, tier: tier)

        recon
      end

      # Keep only proposed claims whose key is in the contract's allowed vocabulary.
      # Preserves order; drops nothing extra. A nil/blank proposal array stays as-is.
      def filter_claims_to_contract(proposed, contract)
        return proposed if proposed.blank?
        allowed = Array(contract.keys).map(&:to_s).to_set
        proposed.select do |raw|
          key = (raw["key"] || raw[:key]).to_s
          allowed.include?(key)
        end
      end

      # Materialize each suggestion the model proposed into an Enliterator::Suggestion
      # row carrying full provenance (tendable, stream, final tier/model, final visit).
      # Fires Enliterator.configuration.suggestion_sink per row when configured.
      def persist_suggestions!(suggestions, visit:, tier:)
        return if suggestions.blank?

        sink = Enliterator.configuration.suggestion_sink
        # v0.9 convergence: a key the curator already mapped/approved/rejected must
        # NOT re-file (the queue would re-litigate forever). Suppress it and bump the
        # term's post_verdict_attempts so "the model keeps wanting this" stays visible.
        resolved = Enliterator::Suggestion.resolved_keys

        Array(suggestions).each do |raw|
          next unless raw.respond_to?(:[])
          proposed_key = (raw["proposed_key"] || raw[:proposed_key]).to_s
          next if proposed_key.blank?

          if resolved.include?(proposed_key)
            Enliterator::ProposedTerm.where(proposed_key: proposed_key)
              .update_all("post_verdict_attempts = post_verdict_attempts + 1, updated_at = NOW()")
            next
          end

          attrs = {
            tendable:     tendable,
            stream:       stream,
            proposed_key: proposed_key,
            rationale:    raw["rationale"] || raw[:rationale],
            tier:         tier.to_s,
            model:        visit.model,
            visit:        visit
          }
          # Only set example_value when the model provided one, so the column keeps
          # its jsonb default ({}) otherwise.
          example = raw.key?("example_value") ? raw["example_value"] : raw[:example_value]
          attrs[:example_value] = example unless example.nil?

          suggestion = Enliterator::Suggestion.create!(**attrs)

          sink.call(suggestion) if sink.respond_to?(:call)
        end
      end

      # A junior visit whose reconciliation was discarded by escalation. It stays
      # in the immutable history as provenance, but is NOT authoritative.
      def mark_superseded!(visit)
        visit.update!(applied: false)
      end

      # Clamp the policy's chosen tier into the allowed ladder. If the assigned
      # tier is disallowed (constraints), start at the first allowed tier.
      def clamp_start_tier(tier, allowed)
        tier = tier.to_s
        allowed.include?(tier) ? tier : allowed.first
      end

      # The escalation climb available from `start_tier`, restricted to the
      # allowed set, order preserved. Always begins with start_tier.
      def ladder_climb(start_tier, allowed)
        idx = allowed.index(start_tier)
        return [ start_tier ] if idx.nil?
        allowed[idx..] || [ start_tier ]
      end

      # Call #tend, passing the optional `tags:`/`contract:` keywords ONLY when the
      # adapter's #tend accepts them. `contract:` is additionally passed only when
      # non-nil, so an unconstrained stream (no contract) yields a call byte-identical
      # to v0.2 even on adapters that DO accept `contract:`. The Gateway accepts both;
      # Null/Bedrock accept `contract:` (and ignore it); per-tier stubs that accept
      # only `tags:` (escalation spec) still work — they're never handed a contract.
      def tend_with_optional_kwargs(adapter, text:, stream:, state:, neighbors:, tags:, contract:, required: nil)
        kwargs = { text: text, stream: stream, state: state, neighbors: neighbors }
        kwargs[:tags]     = tags     if adapter_accepts_kwarg?(adapter, :tags)
        kwargs[:contract] = contract if !contract.nil? && adapter_accepts_kwarg?(adapter, :contract)
        kwargs[:required] = required if !required.nil? && adapter_accepts_kwarg?(adapter, :required)
        adapter.tend(**kwargs)
      end

      def adapter_accepts_kwarg?(adapter, name)
        method = adapter.method(:tend)
        method.parameters.any? { |type, pname| pname == name && %i[key keyreq].include?(type) }
      rescue NameError
        false
      end

      # LiteLLM spend tags for one gateway request. The join key to LiteLLM's
      # authoritative dollars; also the shape Spend.by_stream approximates locally.
      def spend_tags(tier:, step:)
        [
          "enliterator",
          "host:#{host_name}",
          "stream:#{stream}",
          "tier:#{tier}",
          "esc:#{step}",
          "record:#{tendable.class.name}/#{tendable.id}"
        ]
      end

      def host_name
        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.class.module_parent_name.to_s.underscore
        else
          "host"
        end
      rescue StandardError
        "host"
      end

      # ---- v0.5: silent-failure refusal + structured logging ---------------

      # Refuse to run a real tend through the inert Null adapter on the staffing
      # path. Raising HERE — before any Visit row is created — means a misconfigured
      # run (e.g. no ENLITERATOR_LLM_KEY) fails LOUDLY with ZERO phantom "succeeded"
      # Visit rows, instead of silently no-op-succeeding. Tests that legitimately
      # exercise Null set configuration.allow_null_llm = true (the suite opts in).
      def refuse_null!(adapter, tier)
        return unless adapter.is_a?(Enliterator::Adapters::LLM::Null)
        return if Enliterator.configuration.allow_null_llm

        raise Enliterator::ConfigurationError,
              "Enliterator resolved the Null LLM adapter for tier #{tier.inspect} on a real tend " \
              "(#{tendable_ref}, stream #{stream.inspect}): no gateway key and no llm_adapter are " \
              "configured, so nothing would actually run. Set ENLITERATOR_LLM_KEY (or " \
              "configuration.llm_adapter), or set configuration.allow_null_llm = true to permit the " \
              "inert adapter."
      end

      # A stable "Class/id" reference for logs and error messages.
      def tendable_ref
        "#{tendable.class.name}/#{tendable.id}"
      end

      # True when ANY required key is absent from the proposed claims, or present
      # with a blank value. The signal that forces escalation / bars verified. A
      # claim "meets" a required key when it carries a non-blank value (op-agnostic:
      # ADD/UPDATE/NOOP of a real value all assert the fact).
      def required_keys_unmet?(required, claims)
        req = Array(required).map(&:to_s)
        return false if req.empty?

        satisfied = {}
        Array(claims).each do |c|
          next unless c.is_a?(Hash)
          key = (c["key"] || c[:key]).to_s
          val = c.key?("value") ? c["value"] : c[:value]
          satisfied[key] = true unless blank_value?(val)
        end
        req.any? { |k| !satisfied[k] }
      end

      # Blank = nil, empty/whitespace string, or empty array/hash.
      def blank_value?(value)
        return true if value.nil?
        return value.strip.empty? if value.is_a?(String)
        return value.empty? if value.respond_to?(:empty?)
        false
      end

      # Emit one structured log line for a tending event, nil-safe (no logger → no-op).
      # Shape: "[enliterator] event=<event> k=v k=v ...". Whitespace values are quoted;
      # nils dropped. Cheap; never raises. This is the active layer the silent failure
      # lacked — the `resolve` event names the adapter class + model_id every tend.
      def log_event(event, **fields)
        logger = Enliterator.logger
        return unless logger

        pairs = fields.compact.map { |k, v| "#{k}=#{log_val(v)}" }
        logger.info("[enliterator] event=#{event} #{pairs.join(' ')}".strip)
      rescue StandardError
        nil
      end

      def log_val(value)
        s = value.to_s
        s.match?(/\s/) ? s.inspect : s
      end

      # Total tokens out of a Visit.tokens jsonb, tolerant of string/symbol keys.
      def token_total(tokens)
        return 0 unless tokens.is_a?(Hash)
        (tokens["total"] || tokens[:total] || 0).to_i
      end

      # Op-count summary "+a ~u -d =n" from a reconciliation hash, for one-line logs.
      def recon_ops(recon)
        r = recon || {}
        "+#{Array(r[:added] || r['added']).size}" \
        " ~#{Array(r[:updated] || r['updated']).size}" \
        " -#{Array(r[:deleted] || r['deleted']).size}" \
        " =#{Array(r[:noop] || r['noop']).size}"
      end

      # ---- shared visit finalization (back-compat path) --------------------

      def finalize_succeeded!(visit, response, recon, parsed, started, neighbors:, state:)
        finished    = Time.current
        duration_ms = ((finished - started) * 1000).round

        visit.update!(
          status:         "succeeded",
          raw_response:   response.respond_to?(:raw) ? (response.raw || {}) : {},
          reconciliation: recon,
          confidence:     parsed["confidence"],
          input_refs:     input_refs_for(visit, neighbors: neighbors, state: state),
          tokens:         tokens_of(response),
          duration_ms:    duration_ms,
          finished_at:    finished
        )
        log_event("visit", visit_id: visit.id, stream: stream, tier: visit.tier, step: 0,
                           confidence: visit.confidence, applied: visit.applied,
                           ops: recon_ops(recon), tokens: token_total(visit.tokens),
                           duration_ms: duration_ms, status: "succeeded", back_compat: true)
      end

      def fail_visit!(visit, error)
        visit.update_columns(
          status:      "failed",
          error:       error.message,
          finished_at: Time.current,
          updated_at:  Time.current
        )
        log_event("fail", visit_id: visit.id, stream: stream, tier: visit.tier,
                          status: "failed", error: error.message)
      end

      def input_refs_for(visit, neighbors:, state:)
        {
          prior_visit_ids: prior_visit_ids(visit),
          neighbor_ids:    neighbors.map { |n| neighbor_id(n) }.compact,
          claim_keys:      Array(state[:claims]).map { |c| c[:key] }.compact
        }
      end

      def tokens_of(response)
        response.respond_to?(:tokens) ? (response.tokens || {}) : {}
      end

      # Merge the parsed self-escalate flag into the raw response hash so
      # Policy#escalate? (which reads visit.raw_response) can see it. Leaves the
      # raw provider payload otherwise intact.
      def raw_with_escalate(response, parsed)
        raw = response.respond_to?(:raw) ? (response.raw || {}) : {}
        raw = raw.is_a?(Hash) ? raw.dup : {}
        flag = parsed.is_a?(Hash) ? (parsed["escalate"] || parsed[:escalate]) : nil
        raw["escalate"] = !!flag unless flag.nil?
        raw
      end

      # ---- reconcile helpers (shared) --------------------------------------

      # A created/updated claim may be `verified` only when the tier is permitted
      # AND the model asserted it — a high per-claim confidence or an explicit
      # verified/asserted flag. Otherwise it stays `draft`. Below the verify floor,
      # may_verify is false and claims are always draft (no cheap pass poisons the well).
      def claim_status(may_verify:, confidence:, raw:)
        return "draft" unless may_verify
        return "verified" if model_asserts_verified?(raw, confidence)
        "draft"
      end

      def model_asserts_verified?(raw, confidence)
        return true if truthy?(raw["verified"] || raw[:verified])
        asserted = raw["status"] || raw[:status]
        return true if asserted.to_s.downcase == "verified"
        confidence.to_f >= Enliterator.configuration.escalation_threshold &&
          confidence.to_f >= 0.6
      end

      def truthy?(value)
        value == true || value == "true" || value == 1 || value == "1"
      end

      # Resolve the proposed op, defaulting based on whether a live claim exists.
      def normalize_op(op, existing)
        normalized = op.to_s.strip.upcase
        return normalized if %w[ADD UPDATE DELETE NOOP].include?(normalized)

        existing ? "UPDATE" : "ADD"
      end

      def live_claim_for(key)
        tendable.enliterator_claims.live.find_by(key: key)
      end

      # The prior AUTHORITATIVE visits this pass read for context (same stream, the
      # 5 most recent applied visits preceding this one — matching literacy_state).
      def prior_visit_ids(visit)
        tendable.enliterator_visits
          .applied
          .where(stream: stream)
          .where.not(id: visit.id)
          .order(created_at: :desc)
          .limit(5)
          .pluck(:id)
      end

      def create_claim(key:, value:, confidence:, visit:, attributed_to:, tier:, status: "draft", derived_from: [])
        tendable.enliterator_claims.create!(
          key:           key,
          value:         value,
          confidence:    confidence,
          status:        status,
          visit:         visit,
          attributed_to: attributed_to,
          tier:          tier,
          derived_from:  derived_from
        )
      end

      # An Embedding row's stable identity for input_refs provenance.
      def neighbor_id(neighbor)
        neighbor.respond_to?(:id) ? neighbor.id : nil
      end
    end
  end
end
