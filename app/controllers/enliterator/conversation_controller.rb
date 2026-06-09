module Enliterator
  # Converse with the enliteration. `index` renders the chat page (with the
  # self-portrait above it); `stream` is a Server-Sent-Events endpoint that streams
  # the answer token-by-token via ActionController::Live.
  class ConversationController < ApplicationController
    include ActionController::Live

    def index
      @synopsis = Enliterator::Synopsis.build(context: current_context)
    end

    def stream
      response.headers["Content-Type"]      = "text/event-stream"
      response.headers["Cache-Control"]     = "no-cache"
      response.headers["X-Accel-Buffering"] = "no" # disable proxy buffering (nginx/Caddy)

      provenance = Enliterator::Conversation.new(context: current_context).reply(
        question: params[:question].to_s,
        history:  parse_history,
        stream:   true
      ) { |delta| sse(:token, t: delta) }

      sse(:provenance, records: provenance[:records], tier: provenance[:tier], degraded: provenance[:degraded])
      sse(:done, {})
    rescue ActionController::Live::ClientDisconnected
      # client navigated away mid-stream — nothing to clean up beyond the ensure
    rescue => e
      Enliterator.logger&.error("[enliterator] conversation stream error: #{e.class}: #{e.message}")
      # status/headers are already committed once streaming began; surface as an event
      sse(:error, message: "conversation failed") rescue nil
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
