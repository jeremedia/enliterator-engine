module Enliterator
  # v0.26: the MCP endpoint — one POST route speaking the Model Context
  # Protocol's minimum (Streamable HTTP, JSON-RPC 2.0, tools only). No SSE,
  # no sessions, no resources/prompts: every request gets one JSON response.
  # Wire an agent up with:
  #
  #   claude mcp add --transport http enliterator http://localhost:3055/enliterator/mcp
  #
  # Auth posture is the mount's, like every surface — the host's auth wrap
  # covers /enliterator/mcp automatically.
  #
  # Error discipline: protocol misses are JSON-RPC errors (-32601 unknown
  # method, -32602 bad arguments — things the model can't fix by retrying
  # differently get named precisely); tool-execution failures return
  # `isError: true` with an ACTIONABLE message (never a backtrace), so the
  # agent can adjust and retry.
  class McpController < ApplicationController
    # MCP clients carry no CSRF token; this endpoint is an API, not a form.
    skip_forgery_protection

    PROTOCOL_VERSION = "2025-11-25".freeze

    def rpc
      response.set_header("MCP-Protocol-Version", PROTOCOL_VERSION)
      message = parse_message
      return if performed?

      # Notifications (initialized, cancelled, …) get 202 + empty body.
      if message["id"].nil?
        return head :accepted
      end

      case message["method"]
      when "initialize"      then render_result(message, initialize_result(message))
      when "ping"            then render_result(message, {})
      when "tools/list"      then render_result(message, { tools: Enliterator::Mcp.listing })
      when "tools/call"      then tools_call(message)
      else
        render_error(message, -32601, "method not found: #{message['method']}")
      end
    end

    def method_not_allowed
      head :method_not_allowed
    end

    private

    def parse_message
      body = request.body.read
      msg  = JSON.parse(body)
      unless msg.is_a?(Hash)
        # JSON-RPC batching was removed from the MCP transport; say so.
        render_error({}, -32600, "batch requests are not supported")
        return nil
      end
      msg
    rescue JSON::ParserError
      render_error({}, -32700, "parse error: body is not valid JSON")
      nil
    end

    def initialize_result(message)
      asked = message.dig("params", "protocolVersion").to_s
      {
        protocolVersion: asked.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? asked : PROTOCOL_VERSION,
        capabilities:    { tools: { listChanged: false } },
        serverInfo:      { name: "enliterator", version: Enliterator::VERSION }
      }
    end

    def tools_call(message)
      name = message.dig("params", "name").to_s
      args = message.dig("params", "arguments") || {}
      payload = Enliterator::Mcp.dispatch(name, args)
      render_result(message, {
        content: [ { type: "text", text: JSON.pretty_generate(payload) } ],
        isError: false
      })
    rescue Enliterator::Mcp::InvalidArguments => e
      render_error(message, -32602, e.message)
    rescue StandardError => e
      # The failure is the tool's, not the protocol's: actionable, no backtrace.
      Enliterator.logger&.warn("[enliterator] mcp tool #{name} failed — #{e.class}: #{e.message}")
      render_result(message, {
        content: [ { type: "text", text: "#{name} failed: #{e.message}" } ],
        isError: true
      })
    end

    def render_result(message, result)
      render json: { jsonrpc: "2.0", id: message["id"], result: result }
    end

    def render_error(message, code, text)
      render json: { jsonrpc: "2.0", id: message["id"], error: { code: code, message: text } }
    end
  end
end
