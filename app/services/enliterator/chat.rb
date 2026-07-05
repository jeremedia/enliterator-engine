# frozen_string_literal: true

module Enliterator
  # The Chat namespace's registry of conversational agents (the reference desk).
  # These module-function methods live here — NOT in chat/agent.rb — so that
  # Zeitwerk maps the constant Enliterator::Chat to THIS file: calling
  # Chat.reset! / .for_context / .register from any entry point (e.g. Chat::Loop)
  # autoloads the registry, while Agent.new still autoloads chat/agent.rb on demand.
  module Chat
    module_function

    # The registry. Process-level; reset in specs. config.chat_federation gates
    # whether the controller uses it at all (back-compat: off → byte-identical
    # single-shot RAG; on → controller drives Chat::Loop).
    def registry = (@registry ||= {})
    def reset!   = (@registry = {})
    def agents   = registry.values
    def frontdesk = registry.values.find { |a| a.grounding.nil? }
    def for_context(key) = registry.values.find { |a| a.grounding == key.to_s } || frontdesk

    # Register an agent. Validates the tier resolves to a converse_with_tools-capable
    # adapter NOW (fail-fast at registration, never mid-stream).
    def register(name:, grounding:, system_prompt:, tools:, tier:, routes_to: [], step_cap: nil)
      adapter = Enliterator.llm(tier: tier)
      unless adapter.respond_to?(:converse_with_tools)
        raise Enliterator::ConfigurationError,
              "Chat agent #{name.inspect} tier #{tier.inspect} resolves to #{adapter.class} " \
              "which does not implement converse_with_tools (require the gateway; check the alias is advertised)"
      end

      # Re-registration is a silent overwrite by design (dev reloads clear the
      # module ivar first, so this only fires on a genuine in-process double-
      # registration). Warn so config drift is visible; never raise — a reload
      # that does keep state must not crash boot.
      if registry.key?(name.to_s)
        Enliterator.logger&.warn("[enliterator] chat agent #{name.inspect} re-registered (overwriting prior definition)")
      end

      # Two nil-grounding agents make one unreachable (frontdesk returns whichever
      # registered first) and break routing. Reject the second loudly.
      if grounding.nil? && registry.values.any? { |a| a.grounding.nil? && a.name != name.to_s }
        raise Enliterator::ConfigurationError,
              "a Frontdesk agent (nil grounding) is already registered; only one is allowed"
      end

      registry[name.to_s] = Agent.new(
        name:          name.to_s,
        grounding:     grounding&.to_s,
        system_prompt: system_prompt,
        tools:         Array(tools).map(&:to_s),
        tier:          tier.to_s,
        routes_to:     Array(routes_to).map(&:to_s),
        step_cap:      step_cap
      )
    end

    # v0.37: compose the system content from the layers — register → charter →
    # persona → follow-up directive — each added only when its config is on.
    # Shared by Loop#system_content and the /desks preview (DRY). With
    # everything off this returns the bare persona_text (byte-identical to
    # pre-v0.36). The charter (v0.57) rides INDEPENDENT of chat_register: the
    # collection's identity is grounding fact, not voice — a host with no
    # register but a told charter still speaks its name.
    def compose_system(persona_text)
      [ register_text, charter_text, persona_text,
        (Enliterator::Chat::Followups::DIRECTIVE if Enliterator.configuration.chat_followups) ]
        .compact.join("\n\n")
    end

    # v0.36 register layer (lifted from the Loop). nil/false ⇒ none; true ⇒ the
    # built-in DEFAULT; a String ⇒ that custom register.
    def register_text
      r = Enliterator.configuration.chat_register
      return nil unless r
      r == true ? Enliterator::Chat::Register::DEFAULT : r.to_s
    end

    # v0.57: the told identity as one grounding block. nil (no layer) when no
    # charter is configured/told — the compact.join is byte-identical without it.
    def charter_text
      c = Enliterator::Charter.read
      return nil if c.nil? || c[:told].empty?

      t = c[:told]
      parts = []
      if t[:proper_noun].present?
        parts << "This collection is #{t[:proper_noun]}#{t[:identity].present? ? " — #{t[:identity]}" : ''}."
      end
      parts << "Its purpose: #{t[:purpose]}."   if t[:purpose].present?
      parts << "Its audience: #{t[:audience]}." if t[:audience].present?
      parts.presence&.join(" ")
    end
  end
end
