# frozen_string_literal: true

require "rails_helper"

# v0.5 active observability. Before this, the Visitor emitted ZERO log lines — the
# Null silent-failure was invisible in any log tail. Now every tend logs a `resolve`
# line naming the adapter (the line that would have screamed "adapter=…::Null"), a
# `visit` line per outcome, and a `fail` line on error.
RSpec.describe "Enliterator::Tending::Visitor structured logging (v0.5)" do
  # Captures every info(...) line.
  class FakeLogger
    attr_reader :lines
    def initialize = @lines = []
    def info(msg) = @lines << msg.to_s
  end

  let(:widget)   { Widget.create!(title: "Acme", body: "A record to log.") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }
  let(:logger)   { FakeLogger.new }

  before { Enliterator.configure { |c| c.logger = logger } }

  describe "resolve event names the resolved adapter (the smoke-alarm line)" do
    it "emits adapter class + model_id when the Null adapter resolves" do
      # allow_null_llm is true suite-wide, so Null resolves and runs.
      Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder).call
      resolve = logger.lines.find { |l| l.include?("event=resolve") }
      expect(resolve).to be_present
      expect(resolve).to include("adapter=Enliterator::Adapters::LLM::Null", "model_id=null")
    end
  end

  describe "visit event on the back-compat (injected llm) path" do
    class LogStubLLM
      Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
      def model_id = "stub"
      def tend(text:, facet:, state:, neighbors:)
        Result.new(parsed: { "claims" => [ { "key" => "summary", "op" => "ADD", "value" => "v" } ],
                             "confidence" => 0.9 },
                   raw: {}, tokens: { "total" => 7 })
      end
    end

    it "emits a succeeded visit line" do
      Enliterator::Tending::Visitor.new(widget, facet: "summary", llm: LogStubLLM.new, embedder: embedder).call
      visit = logger.lines.find { |l| l.include?("event=visit") }
      expect(visit).to be_present
      expect(visit).to include("status=succeeded", "back_compat=true")
    end
  end

  describe "fail event when the adapter raises (and the raise propagates)" do
    class BoomLLM
      def model_id = "boom"
      def tend(*) = raise "kaboom"
    end

    it "logs a fail line and re-raises" do
      visitor = Enliterator::Tending::Visitor.new(widget, facet: "summary", llm: BoomLLM.new, embedder: embedder)
      expect { visitor.call }.to raise_error(/kaboom/)
      fail_line = logger.lines.find { |l| l.include?("event=fail") }
      expect(fail_line).to be_present
      expect(fail_line).to include("status=failed")
    end
  end
end
