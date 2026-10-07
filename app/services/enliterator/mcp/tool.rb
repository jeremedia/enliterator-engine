module Enliterator
  module Mcp
    # The tool base: each tool declares a name, a description written FOR an
    # agent (what it's for, when to reach for it), and a plain JSON-Schema
    # input contract; `call(**args)` returns a Hash the controller serializes
    # as one text content block.
    #
    # House disciplines, applied to the agent as a consumer:
    # - BOUNDED: every collection capped, every long value truncated with a
    #   flag — the agent's context window is a budget exactly like the
    #   heartbeat's.
    # - SELF-DESCRIBING: responses carry `next` hints (which tool to call for
    #   depth, which /enliterator path shows a human the same thing) so no
    #   out-of-band knowledge is needed to act correctly.
    class Tool
      VALUE_MAX = 400

      class << self
        attr_reader :tool_name, :description, :input_schema

        # v0.83: tools that read only scope-honoring paths declare it; inside an
        # audience scope Mcp.dispatch refuses every tool that hasn't (fail
        # closed — a tool added later cannot silently read around the scope).
        def honors_member_scope! = (@honors_member_scope = true)
        def honors_member_scope? = !!@honors_member_scope

        def name_and_description(name, desc)
          @tool_name   = name
          @description = desc
        end

        def schema(properties = {}, required: [])
          @input_schema = {
            "type"       => "object",
            "properties" => properties,
            "required"   => required.map(&:to_s)
          }
        end

        # Shared property shorthands.
        def str(desc)  = { "type" => "string", "description" => desc }
        def int(desc)  = { "type" => "integer", "description" => desc }
      end

      private

      # Resolve an optional context KEY (MCP carries no cookies — scope is
      # explicit per call). Unknown keys raise an actionable message.
      def resolve_context(key)
        return nil if key.blank? || key.to_s == "root"
        Enliterator::Context.find_by(key: key.to_s) ||
          raise(ArgumentError,
                "unknown context #{key.inspect} — call collection_overview for the context tree")
      end

      # The status#show allowlist, agent-shaped: registered hosts ∪ Part.
      def find_record!(type, id)
        klass = type.to_s.safe_constantize
        unless Enliterator.tendable_type?(klass)
          raise ArgumentError,
                "unknown record type #{type.inspect} — collection_overview lists the tended types"
        end
        record = klass.find_by(klass.primary_key => id)
        # v0.83: outside the audience scope a record does not exist — the SAME
        # answer as a missing one, so the error is no existence oracle.
        if record.nil? || !Enliterator::MemberScope.include?(record)
          raise ArgumentError, "no #{type} with id #{id.inspect}"
        end
        record
      end

      # v0.83: a claim-addressed tool (quote, provenance) answers only for
      # claims on visible records — the same "no claim" as a missing one.
      def visible_claim!(claim_id)
        claim = Enliterator::Claim.find_by(id: claim_id)
        if claim.nil? || !Enliterator::MemberScope.include?(claim.tendable)
          raise ArgumentError, "no claim ##{claim_id}"
        end
        claim
      end

      def label_for(rec)
        rec.try(:title).presence || rec.try(:name).presence ||
          "#{rec.class.name} ##{rec.id}"
      end

      # v0.64: `cap: nil` returns the FULL value (no truncation) — the single-claim
      # drill-downs (provenance, quote) pass nil so an agent reads the whole claim,
      # not a 400-char card. A positive cap truncates with an ellipsis as before.
      def render_value(value, cap: VALUE_MAX)
        s = value.is_a?(String) ? value : value.to_json
        cap && s.length > cap ? "#{s[0, cap]}…" : s
      end

      def truncated?(value, cap: VALUE_MAX)
        return false if cap.nil?
        s = value.is_a?(String) ? value : value.to_json
        s.length > cap
      end

      # One claim, with its provenance on its sleeve.
      # v0.64: `value_chars` caps the claim value (nil ⇒ FULL). Defaults to VALUE_MAX
      # so a card in a many-claim list (record_entry) stays bounded and byte-identical;
      # single-claim tools pass nil to surface the untruncated value.
      # v0.76: `warrant:`/`warrant_stale:`/`tainted:` may arrive PRECOMPUTED
      # from a batching caller (record_entry) — nil falls back to the per-claim
      # read, so the single-claim path (provenance) is unchanged. This closed
      # the v0.75 N+1: warrant + staleness were computed per card in a 60-card
      # listing, one audits query each.
      def claim_card(claim, verdict: nil, value_chars: VALUE_MAX,
                     warrant: nil, warrant_stale: :compute, tainted: :compute)
        gated = Enliterator.configuration.audit_warrant
        {
          id:            claim.id,
          key:           claim.key,
          value:         render_value(claim.value, cap: value_chars),
          truncated:     truncated?(claim.value, cap: value_chars) || nil,
          confidence:    claim.confidence,
          tier:          claim.tier,
          status:        claim.status,
          locked:        claim.locked || nil,
          attributed_to: claim.attributed_to,
          context:       claim.context&.key || "root",
          # v0.60: the honest epistemic state for an agent reader. Gated + .compact ⇒
          # absent (byte-identical card) when config.audit_warrant is off.
          warrant:       (gated ? (warrant || claim.warrant) : nil),
          # v0.75: has the terrain moved since this claim was last checked?
          # true/false when knowable, ABSENT when unknown (pre-v0.75 mints) or
          # the flag is off — same gate, same .compact discipline.
          warrant_stale: (gated ? (warrant_stale == :compute ? claim.warrant_stale? : warrant_stale) : nil),
          # v0.76: fruit of the poisonous tree — a basis ancestor was ruled
          # defective and this claim has not cited its way out. true is the
          # signal; false/unknown are ABSENT (compact discipline).
          tainted:       (gated ? (((tainted == :compute ? claim.tainted? : tainted) || nil)) : nil),
          # v0.79: what KIND of text this value is, so the desk cannot mistake a
          # cataloger's synthesis for the author's words. ABSENT flag-off.
          nature:        (Enliterator.configuration.chat_attribution ? claim_nature(claim) : nil),
          audit_verdict: verdict
        }.compact
      end

      # v0.79: engine-read (visit-bearing) ⇒ the catalog's claim; the told charter;
      # a human's assertion; otherwise a host-seeded assertion.
      def claim_nature(claim)
        if claim.visit_id then "catalog_claim"
        elsif Enliterator::Charter.charter_key?(claim.key) then "charter"
        elsif claim.attributed_to.to_s.start_with?("human") then "curator_assertion"
        else "host_assertion"
        end
      end

      def entry_path(type, id) = "/enliterator/status/#{type}/#{id}"
    end
  end
end
