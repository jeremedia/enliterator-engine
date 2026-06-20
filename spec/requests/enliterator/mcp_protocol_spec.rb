# frozen_string_literal: true

require "rails_helper"

# v0.26 — the MCP endpoint: the protocol minimum (JSON-RPC 2.0 over POST,
# tools only, stateless, plain JSON responses). Protocol misses are JSON-RPC
# errors; tool failures are isError results with actionable text.
RSpec.describe "Enliterator MCP protocol", type: :request do
  def rpc(body)
    post "/enliterator/mcp", params: body.to_json,
                             headers: { "CONTENT_TYPE" => "application/json",
                                        "ACCEPT" => "application/json, text/event-stream" }
    response.body.present? ? JSON.parse(response.body) : nil
  end

  it "answers initialize with the protocol echo, tools capability, and serverInfo" do
    out = rpc(jsonrpc: "2.0", id: 1, method: "initialize",
              params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "spec" } })
    expect(response).to have_http_status(:ok)
    expect(response.headers["MCP-Protocol-Version"]).to eq("2025-11-25")
    expect(out["result"]["protocolVersion"]).to eq("2025-11-25")
    expect(out["result"]["capabilities"]["tools"]).to eq("listChanged" => false)
    expect(out["result"]["serverInfo"]["name"]).to eq("enliterator")
  end

  it "accepts notifications with 202 and an empty body" do
    post "/enliterator/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
                             headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:accepted)
    expect(response.body).to be_blank
  end

  it "lists all fifteen tools with valid input schemas" do
    out = rpc(jsonrpc: "2.0", id: 2, method: "tools/list", params: {})
    tools = out["result"]["tools"]
    expect(tools.size).to eq(15)
    expect(tools.map { |t| t["name"] }).to include(
      "collection_overview", "search", "record_entry", "trajectory",
      "provenance", "quote", "accuracy", "recent_activity", "lacunae", "propose_term", "flag_claim"
    )
    tools.each do |t|
      expect(t["description"]).to be_present
      expect(t["inputSchema"]["type"]).to eq("object")
      expect(t["inputSchema"]).to have_key("required")
    end
  end

  it "calls a tool and returns one text content block" do
    Widget.create!(title: "A", body: "b")
    out = rpc(jsonrpc: "2.0", id: 3, method: "tools/call",
              params: { name: "collection_overview", arguments: {} })
    expect(out["result"]["isError"]).to be(false)
    payload = JSON.parse(out["result"]["content"].first["text"])
    expect(payload["stats"]).to include("enliterated", "corpus")
    expect(payload["next"]).to be_present     # self-describing
  end

  it "names unknown methods (-32601), bad arguments (-32602), and parse errors (-32700)" do
    expect(rpc(jsonrpc: "2.0", id: 4, method: "resources/list").dig("error", "code")).to eq(-32601)
    expect(rpc(jsonrpc: "2.0", id: 5, method: "tools/call",
               params: { name: "search", arguments: {} }).dig("error", "code")).to eq(-32602)
    expect(rpc(jsonrpc: "2.0", id: 6, method: "tools/call",
               params: { name: "no_such_tool", arguments: {} }).dig("error", "code")).to eq(-32602)
    post "/enliterator/mcp", params: "not json{", headers: { "CONTENT_TYPE" => "application/json" }
    expect(JSON.parse(response.body).dig("error", "code")).to eq(-32700)
  end

  it "renders a tool failure as isError with an actionable message, never a backtrace" do
    out = rpc(jsonrpc: "2.0", id: 7, method: "tools/call",
              params: { name: "record_entry", arguments: { type: "String", id: "1" } })
    expect(out["result"]["isError"]).to be(true)
    text = out["result"]["content"].first["text"]
    expect(text).to include("unknown record type")
    expect(text).not_to include("app/services")   # no backtrace leakage
  end

  it "refuses non-POST verbs with 405" do
    get "/enliterator/mcp"
    expect(response).to have_http_status(:method_not_allowed)
  end
end
