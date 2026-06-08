# frozen_string_literal: true

require "rails_helper"

# v0.5 silent-failure hardening. The incident: with no gateway key configured,
# Enliterator.llm(tier:) resolves to the inert Null adapter, which used to no-op
# SUCCEED — writing phantom "succeeded" Visit rows that called no model. This spec
# pins the guard: on the staffing path, a Null resolution RAISES (loudly) BEFORE any
# Visit row is created, unless configuration.allow_null_llm is true.
#
# NB: rails_helper sets allow_null_llm = true suite-wide, so these examples that
# exercise the guard flip it back to false explicitly.
RSpec.describe "Enliterator::Tending::Visitor null-adapter guard (staffing path)" do
  let(:widget)   { Widget.create!(title: "Acme", body: "A record with no model wired.") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # No gateway key, no llm_adapter, no staffing → default policy routes "summary"
  # to "cheap", and Enliterator.llm(tier: "cheap") resolves to Null.
  def tend!
    Enliterator::Tending::Visitor.new(widget, stream: "summary", embedder: embedder).call
  end

  describe "when allow_null_llm is false (production default)" do
    before { Enliterator.configuration.allow_null_llm = false }

    it "raises ConfigurationError naming the Null adapter" do
      expect { tend! }.to raise_error(Enliterator::ConfigurationError, /Null/)
    end

    it "creates ZERO phantom Visit rows (the guard fires before create!)" do
      expect { tend! rescue nil }.not_to change { widget.enliterator_visits.count }.from(0)
    end
  end

  describe "when allow_null_llm is true (tests / explicit opt-in)" do
    before { Enliterator.configuration.allow_null_llm = true }

    it "permits the inert adapter: a succeeded, zero-claim visit" do
      visit = nil
      expect { visit = tend! }.not_to raise_error
      expect(visit.status).to eq("succeeded")
      expect(widget.enliterator_claims.live.count).to eq(0)
    end
  end

  describe "the no-tier path is unaffected by the guard" do
    it "Enliterator.llm (no tier) still resolves to Null" do
      expect(Enliterator.llm).to be_a(Enliterator::Adapters::LLM::Null)
    end
  end
end
