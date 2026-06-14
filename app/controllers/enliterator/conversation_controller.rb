module Enliterator
  # Converse with the enliteration. `index` renders the chat page (with the
  # self-portrait above it); `stream` is a Server-Sent-Events endpoint that streams
  # the answer token-by-token via ActionController::Live.
  class ConversationController < ApplicationController
    include ActionController::Live

    def index
      @synopsis = Enliterator::Synopsis.build(context: current_context)
      # The scope banner: the context cookie persists across visits, so the page
      # must SAY what it's scoped to — a chat silently pinned to an 82-record
      # sub-collection is indistinguishable from a broken one.
      @scope_count = current_context&.memberships&.count
    end

    def stream
      response.headers["Content-Type"]      = "text/event-stream"
      response.headers["Cache-Control"]     = "no-cache"
      response.headers["X-Accel-Buffering"] = "no" # disable proxy buffering (nginx/Caddy)

      if Enliterator.configuration.chat_followups && params[:from_followup].present?
        Enliterator.logger&.info("[enliterator] followup_click q=#{params[:question].to_s[0, 80].inspect}")
      end

      if Enliterator.configuration.chat_federation
        agent = Enliterator::Chat.for_context(current_context&.key)
        # Capture: when chat_retention is on, tee the sink so every event is also
        # recorded. When retention is off, `captured` stays nil, sink == method(:sse)
        # (byte-identical to v0.38 — no extra rows, no observable change).
        captured = [] if Enliterator.configuration.chat_retention
        sink = captured ? ->(ev, data) { captured << { "event" => ev.to_s, "data" => data }; sse(ev, data) } : method(:sse)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # error_detail? is the per-surface decision point — passed explicitly here so
        # the future public desk can pass `false` regardless of env. (The Loop already
        # defaults to the resolver; this makes the surface's choice the authority.)
        Enliterator::Chat::Loop.new(agent: agent, sink: sink,
                                    error_detail: Enliterator.configuration.error_detail?).run(params[:question].to_s)
        if captured
          conv = Enliterator::Chat::Conversation.find_or_create_by(token: params[:conversation_token].presence || SecureRandom.uuid) do |c|
            c.context = current_context&.key
            c.source  = "live"
          end
          Enliterator::Chat::Recorder.record(
            conversation: conv, question: params[:question].to_s, events: captured,
            initial_desk: agent.name,
            elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
        end
      else
        # ===== existing single-shot path — preserve VERBATIM =====
        provenance = Enliterator::Conversation.new(context: current_context).reply(
          question: params[:question].to_s,
          history:  parse_history,
          stream:   true
        ) { |delta| sse(:token, t: delta) }

        # `context` makes each answer self-describing about its scope — the
        # retrieval pool that produced it, not just which records it cited.
        sse(:provenance, records: provenance[:records], tier: provenance[:tier],
                         degraded: provenance[:degraded],
                         context: current_context&.key || "root")
        sse(:done, {})
        # ===== end existing path =====
      end
    rescue ActionController::Live::ClientDisconnected
      # client navigated away mid-stream — nothing to clean up beyond the ensure
    rescue => e
      Enliterator.logger&.error("[enliterator] conversation stream error: #{e.class}: #{e.message}")
      # status/headers are already committed once streaming began; surface as an event.
      # ErrorReport gates ACTIONABLE detail behind error_detail? — off (prod) yields the
      # byte-identical {message: "conversation failed"} floor; on (dev) adds detail/where/hint.
      # `message:` stays the static literal — NEVER e.message — so detail-off can't leak.
      sse(:error, Enliterator::Chat::ErrorReport.build(
        e, where: { stage: "stream" },
        detail: Enliterator.configuration.error_detail?,
        message: "conversation failed")) rescue nil
    ensure
      response.stream.close
    end

    def replay
      return head :not_found unless Enliterator.configuration.chat_retention
      conv = Enliterator::Chat::Conversation.find_by(id: params[:id]) ||
             Enliterator::Chat::Conversation.find_by(token: params[:id])
      return head :not_found unless conv

      response.headers["Content-Type"]      = "text/event-stream"
      response.headers["Cache-Control"]     = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      conv.turns.each do |turn|
        sse(:replay_user, q: turn.question)            # client renders the patron bubble + a fresh turn
        Array(turn.events).each do |e|
          name = (e["event"] || e[:event]).to_s
          data = e["data"] || e[:data] || {}
          next if name.empty?
          sse(name, data)
          sleep 0.012 if name == "token" && !Rails.env.test?  # animate the stream live; instant in tests
        end
      end
      sse(:replay_end, {})
    rescue ActionController::Live::ClientDisconnected
      # client navigated away mid-replay — nothing to clean up beyond the ensure
    rescue => e
      Enliterator.logger&.error("[enliterator] replay error: #{e.class}: #{e.message}")
      sse(:error, message: "replay failed") rescue nil
    ensure
      response.stream.close
    end

    private

    def sse(event, data)
      response.stream.write("event: #{event}\n")
      response.stream.write("data: #{data.to_json}\n\n")
    end

    # history is a JSON array of {role, content} turns from the client. Tolerant.
    def parse_history
      raw = params[:history]
      return [] if raw.blank?
      parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
      Array(parsed).map { |t| { role: (t["role"] || t[:role]).to_s, content: (t["content"] || t[:content]).to_s } }
    rescue JSON::ParserError
      []
    end
  end
end
