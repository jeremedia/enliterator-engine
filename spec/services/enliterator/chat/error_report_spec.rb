# frozen_string_literal: true
require "rails_helper"

# v0.30: the keys-canary. ErrorReport is the SOLE constructor of the chat
# :error SSE payload, and detail:false is the prod/off floor — it can NEVER
# yield anything but {message:}. The first block below is written to FAIL if
# any code path ever adds a key past the gate (the canary in the coal mine).
RSpec.describe Enliterator::Chat::ErrorReport do
  # A battery spanning every HINTS rule plus a generic catch-all. Each is the
  # KIND of error a real loop/controller would hand us — by class or message.
  def error_battery
    sso        = StandardError.new("ExpiredToken: The security token included in the request is expired")
    timeout    = StandardError.new("Faraday::TimeoutError: request timed out after 180s")
    model      = StandardError.new("BadRequest: model 'bedrock-sonnet' not found on gateway")
    bad_gw     = StandardError.new("ECONNREFUSED: connection refused (502 from upstream)")
    bad_key    = StandardError.new("401 Unauthorized: invalid api key")
    not_impl   = NotImplementedError.new # bare — must match on CLASS NAME alone
    config_err = Enliterator::ConfigurationError.new("tier resolves to an adapter without converse_with_tools")
    generic    = StandardError.new("something nobody has a hint for")
    [ sso, timeout, model, bad_gw, bad_key, not_impl, config_err, generic ]
  end

  describe "the keys-canary (detail:false is the floor)" do
    it "yields EXACTLY {message:} for every kind of error — nothing leaks past the gate" do
      error_battery.each do |err|
        report = described_class.build(err, where: { stage: "x" }, detail: false, message: "msg")
        expect(report.keys).to eq([ :message ]),
          "#{err.class} (#{err.message.inspect}) leaked keys: #{report.keys.inspect}"
        expect(report[:message]).to eq("msg")
      end
    end

    it "never derives :message from error.message — the secret never appears" do
      report = described_class.build(StandardError.new("SECRET"), where: {}, detail: false, message: "generic")
      expect(report[:message]).to eq("generic")
      expect(report.to_s).not_to include("SECRET")
    end

    it "holds the floor even with a nil/odd where" do
      [ nil, {}, { stage: nil }, "garbage" ].each do |w|
        report = described_class.build(StandardError.new("x"), where: w, detail: false, message: "m")
        expect(report.keys).to eq([ :message ])
      end
    end
  end

  describe "detail:true (actionable payload)" do
    it "carries :detail as \"class: message\"" do
      err    = StandardError.new("boom")
      report = described_class.build(err, where: { stage: "stream" }, detail: true, message: "Something went wrong")
      expect(report[:message]).to eq("Something went wrong")  # still the caller's literal
      expect(report[:detail]).to eq("StandardError: boom")
    end

    it "humanizes where into a compact ' · '-joined string, skipping nils" do
      report = described_class.build(StandardError.new("x"),
        where: { stage: "model call", agent: "CHDS Theses", tier: "bedrock-sonnet" },
        detail: true, message: "m")
      expect(report[:where]).to eq("model call · CHDS Theses · bedrock-sonnet")

      partial = described_class.build(StandardError.new("x"),
        where: { stage: "tool", tool: nil, agent: "Frontdesk" }, detail: true, message: "m")
      expect(partial[:where]).to eq("tool · Frontdesk")
    end

    it "tolerates an empty / nil where → :where == \"\" (no raise)" do
      [ {}, nil ].each do |w|
        report = described_class.build(StandardError.new("x"), where: w, detail: true, message: "m")
        expect(report[:where]).to eq("")
      end
    end

    it "attaches the right :hint for each known error (first-match-wins)" do
      cases = {
        "ExpiredToken: token expired"                      => "aws sso login",
        "Faraday::TimeoutError: request timed out"         => "timed out",
        "BadRequest: model 'x' not found"                  => "not be advertised",
        "ECONNREFUSED: connection refused"                 => "unreachable",
        "401 Unauthorized: invalid api key"                => "rejected the key"
      }
      cases.each do |msg, substring|
        report = described_class.build(StandardError.new(msg), where: {}, detail: true, message: "m")
        expect(report[:hint]).to be_present
        expect(report[:hint].downcase).to include(substring),
          "#{msg.inspect} → expected hint containing #{substring.inspect}, got #{report[:hint].inspect}"
      end
    end

    it "matches a hint on the CLASS NAME even when the message is empty" do
      report = described_class.build(NotImplementedError.new, where: {}, detail: true, message: "m")
      expect(report[:hint]).to be_present
      expect(report[:hint].downcase).to include("converse_with_tools")
    end

    it "matches ConfigurationError to the adapter hint" do
      report = described_class.build(Enliterator::ConfigurationError.new("bad tier"),
        where: {}, detail: true, message: "m")
      expect(report[:hint].downcase).to include("converse_with_tools")
    end

    it "omits :hint entirely for an unknown error (no empty key)" do
      report = described_class.build(StandardError.new("nobody hints for this"),
        where: {}, detail: true, message: "m")
      expect(report).not_to have_key(:hint)
    end
  end
end
