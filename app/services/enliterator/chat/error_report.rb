# frozen_string_literal: true

module Enliterator
  module Chat
    # v0.30: the SOLE constructor of the chat :error SSE payload. The chat
    # surface emits :error when a turn fails; today the actionable detail (which
    # tier, which exception, the cause) is dropped on the floor. This module
    # builds a payload that carries that detail WHEN ENABLED and ONLY a generic
    # message otherwise — the security-critical invariant being that detail:off
    # can NEVER leak an internal. The gate (`return h unless detail`) is the
    # whole point: nothing may be added past it, and `message` is ALWAYS the
    # caller's literal — never derived from error.message, which would route a
    # secret around the gate. Spec-pinned by the keys-canary.
    #
    # Pure, no side effects (cf. Widget). Unlike Widget this renders NO HTML —
    # the chat client escapes via textContent — so there is no h() here.
    module ErrorReport
      module_function

      # Ordered, first-match-wins: [Regexp, hint]. Matched against
      # "#{error.class}: #{error.message}" so a bare error (empty message) still
      # matches on its class name. Patterns are narrow; an unmatched error gets
      # NO hint key. Most-specific first.
      HINTS = [
        [ /ExpiredToken|security token.*expired|InvalidGrant|\bsso\b/i,
          "AWS SSO session likely expired — re-run `aws sso login` (the gateway's Bedrock route needs it)." ],
        [ /Faraday::TimeoutError|Net::ReadTimeout|\bTimeout\b|timed out/i,
          "The LLM gateway timed out — retry, or the tier is slow (per-call cap is gateway_timeout)." ],
        [ /model.*not.*found|no.*deployment|BadRequest.*model|\b404\b/i,
          "That tier alias may not be advertised on the gateway — check the model alias / config." ],
        [ /ECONNREFUSED|ConnectionFailed|\b50[23]\b/i,
          "The LLM gateway is unreachable — is llm.domt.app up? Check gateway_base_url." ],
        [ /\b401\b|\b403\b|invalid api key|Unauthorized/i,
          "The gateway rejected the key — check gateway_api_key / ENLITERATOR_LLM_KEY." ],
        [ /NotImplementedError|ConfigurationError/i,
          "This tier resolves to an adapter that can't converse_with_tools — require the gateway (gateway_api_key) for chat." ]
      ].freeze

      # Build the :error payload. `message` is the caller's literal floor —
      # always present, never derived from the error. `where` is a Hash of
      # engine-internal labels (e.g. {stage:, agent:, tier:}). `detail` is the
      # gate: when false, the payload is EXACTLY {message:}.
      def build(error, where:, detail:, message:)
        h = { message: message } # the ONLY always-present key — the prod/off floor
        return h unless detail   # the gate: NOTHING else may be added past here

        h[:detail] = "#{error.class}: #{error.message}"
        h[:where]  = humanize(where)
        hint = hint_for(error)
        h[:hint] = hint if hint
        h
      end

      # Engine-internal labels → a compact human string ("model call · CHDS
      # Theses · bedrock-sonnet"). Tolerant of a nil / non-Hash where → "".
      def humanize(where)
        return "" unless where.is_a?(Hash)
        where.values.reject { |v| v.nil? || v.to_s.empty? }.map(&:to_s).join(" · ")
      end

      # First-match-wins over HINTS, matched against class AND message so a bare
      # error still resolves. Unmatched → nil (no hint key is added).
      def hint_for(error)
        subject = "#{error.class}: #{error.message}"
        HINTS.each { |rx, hint| return hint if subject.match?(rx) }
        nil
      end
    end
  end
end
