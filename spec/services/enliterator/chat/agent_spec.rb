# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Agent do
  # A fake adapter that DOES respond to converse_with_tools (the Gateway contract).
  let(:capable) { Class.new { def converse_with_tools(**) = nil }.new }
  # A fake that does NOT (the direct-Bedrock trap).
  let(:incapable) { Class.new { def converse(**) = nil }.new }

  before { Enliterator::Chat.reset! }
  after  { Enliterator::Chat.reset! }

  it "registers a frontdesk (nil grounding) and a specialist, resolvable by name and by context" do
    allow(Enliterator).to receive(:llm).and_return(capable)
    Enliterator::Chat.register(name: "Frontdesk", grounding: nil, system_prompt: "triage",
                               tools: %w[search record_entry], tier: "cheap", routes_to: %w[CHDS])
    Enliterator::Chat.register(name: "CHDS", grounding: "chds-theses", system_prompt: "advise",
                               tools: %w[search record_entry provenance], tier: "bedrock-sonnet")
    expect(Enliterator::Chat.frontdesk.name).to eq("Frontdesk")
    expect(Enliterator::Chat.for_context("chds-theses").name).to eq("CHDS")
    expect(Enliterator::Chat.for_context("unknown")).to eq(Enliterator::Chat.frontdesk)  # fallback
  end

  it "REFUSES to register an agent whose tier resolves to an adapter lacking converse_with_tools" do
    allow(Enliterator).to receive(:llm).with(tier: "bad").and_return(incapable)
    expect {
      Enliterator::Chat.register(name: "X", grounding: nil, system_prompt: "p", tools: [], tier: "bad")
    }.to raise_error(Enliterator::ConfigurationError, /converse_with_tools/)
  end

  it "rejects a second Frontdesk (two nil-grounding agents break routing)" do
    allow(Enliterator).to receive(:llm).and_return(capable)
    Enliterator::Chat.register(name: "F1", grounding: nil, system_prompt: "p", tools: [], tier: "cheap")
    expect {
      Enliterator::Chat.register(name: "F2", grounding: nil, system_prompt: "p", tools: [], tier: "cheap")
    }.to raise_error(Enliterator::ConfigurationError, /Frontdesk/)
  end

  it "an agent exposes its OpenAI tool defs from Mcp.listing filtered to its allow-list" do
    allow(Enliterator).to receive(:llm).and_return(capable)
    a = Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p",
                                   tools: %w[search], tier: "cheap")
    names = a.tool_defs.map { |d| d.dig("function", "name") }
    expect(names).to eq(%w[search])
    expect(a.allows?("search")).to be(true)
    expect(a.allows?("flag_claim")).to be(false)
  end
end
