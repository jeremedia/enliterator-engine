# frozen_string_literal: true

require "rails_helper"

# v0.75 — WARRANT IN TIME. The checking-act made durable, dated against its
# terrain: visits stamp the digest of the text their reader was given;
# `warrant_stale?` re-evaluates the tie against the current terrain (OKNOTOK's
# one-liner — derived, never stored, instrument never auto-revoker); the audit
# sampler examines where the terrain has moved. UNKNOWN is nil, never false.
RSpec.describe "v0.75 warrant in time" do
  class WarrantReaderStub
    Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
    def initialize(claims = [])
      @claims = claims
    end
    def model_id = "stub"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      Result.new(parsed: { "claims" => @claims, "confidence" => 0.9 }, raw: {}, tokens: {})
    end
  end

  let(:widget)   { Widget.create!(title: "T", body: "the original body") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def staff!(stub)
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        assign :summary, tier: "cheap"
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
  end

  def tend!(claims = [])
    staff!(WarrantReaderStub.new(claims))
    Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder).call
  end

  describe "75.1 — the warrant paper (visit source digest)" do
    it "stamps digest + chars of the FULL text the reader was given, staffing path" do
      visit = tend!
      full = widget.enliterator_text(facet: "summary")
      expect(visit.source_digest).to eq(Digest::MD5.hexdigest(full))
      expect(visit.source_chars).to eq(full.length)
    end

    it "stamps the back-compat path too" do
      visit = Enliterator::Tending::Visitor.new(
        widget, facet: "summary", llm: WarrantReaderStub.new, embedder: embedder
      ).call
      expect(visit.source_digest).to eq(Digest::MD5.hexdigest(widget.enliterator_text(facet: "summary")))
    end

    it "COLUMN GUARD: engine code against an unmigrated host schema still tends (digest simply absent)" do
      allow(Enliterator::Visit).to receive(:column_names)
        .and_return(Enliterator::Visit.column_names - %w[source_digest source_chars])
      visit = tend!
      expect(visit.status).to eq("succeeded")
      expect(visit.reload.source_digest).to be_nil
    end
  end

  describe "75.2 — warrant_checked_digest + warrant_stale?" do
    it "checked digest = mint digest for a never-audited claim" do
      tend!([ { "key" => "summary", "value" => "a take" } ])
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim.warrant_checked_digest).to eq(claim.visit.source_digest)
    end

    it "an AUDIT'S digest outranks the mint digest — the audit is the later check" do
      tend!([ { "key" => "summary", "value" => "a take" } ])
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      Enliterator::Audit.create!(claim: claim, verdict: "supported", source: "examiner",
                                 source_digest: "audit-digest")
      expect(claim.warrant_checked_digest).to eq("audit-digest")
    end

    it "THREE-state: false while terrain matches, true after it moves, nil when unknowable" do
      tend!([ { "key" => "summary", "value" => "a take" } ])
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim.warrant_stale?).to be(false)              # store-vs-store, matching

      widget.update!(body: "the terrain moved")
      tend!                                                   # a newer visit stamps the new digest
      expect(claim.reload.warrant_stale?).to be(true)         # checked ≠ latest known

      # UNKNOWN: a pre-v0.75 claim (mint visit carries no digest, no audit digest)
      old_visit = widget.enliterator_visits.create!(facet: "summary", status: "succeeded",
                                                    applied: true, tier: "cheap")
      old = widget.enliterator_claims.create!(key: "old_key", value: "v", status: "draft",
                                              tier: "cheap", visit: old_visit)
      expect(old.warrant_stale?).to be_nil                    # never false, never true
    end

    it "an explicit current_digest wins over the stored comparison (the page idiom)" do
      tend!([ { "key" => "summary", "value" => "a take" } ])
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim.warrant_stale?(claim.warrant_checked_digest)).to be(false)
      expect(claim.warrant_stale?("moved")).to be(true)
    end

    it "the batch helper agrees with the instance read and stays at TWO queries for N claims" do
      tend!([ { "key" => "summary", "value" => "a take" } ])
      widget.update!(body: "the terrain moved")
      tend!([ { "key" => "summary", "value" => "a newer take" } ])
      claims = widget.enliterator_claims.live.where(key: "summary").to_a

      queries = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        # Schema loads (column lookups on first model touch) are not the helper's
        # queries — counting them made this pass or fail with suite ORDER.
        next if payload[:name] == "SCHEMA"
        queries += 1 if payload[:sql] =~ /SELECT/i && payload[:sql] =~ /enliterator_(audits|visits)/
      end
      batch = Enliterator::Claim.warrant_staleness_for(claims)
      ActiveSupport::Notifications.unsubscribe(sub)

      expect(queries).to be <= 3   # one audits + one mint-visits + one latest-visits
      claims.each { |c| expect(batch[c.id]).to eq(c.warrant_stale?) }
    end
  end

  describe "75.3 — the sampler examines where the terrain moved" do
    def claim_with_digest!(key, digest)
      v = widget.enliterator_visits.create!(facet: "authorship", status: "succeeded",
                                            applied: true, tier: "cheap", source_digest: digest,
                                            started_at: 2.days.ago)
      widget.enliterator_claims.create!(key: key, value: "v", status: "draft", tier: "cheap", visit: v)
    end

    it "orders stale-known candidates first WITHIN a cell" do
      fresh = claim_with_digest!("fresh_key", "current")
      stale = claim_with_digest!("stale_key", "old")
      # the record's newest visit says the terrain is now "current"
      widget.enliterator_visits.create!(facet: "authorship", status: "succeeded", applied: true,
                                        tier: "cheap", source_digest: "current", started_at: 1.hour.ago)

      picked = Enliterator::Audit.sample(1)[:claims]
      expect(picked.map(&:key)).to eq([ "stale_key" ])   # the moved-terrain claim leads
      expect([ fresh, stale ].map(&:key)).to include("fresh_key")  # (fresh exists, just not picked)
    end

    it "is pure v0.18 random when no digests exist — inert until the substrate accumulates" do
      v = widget.enliterator_visits.create!(facet: "authorship", status: "succeeded",
                                            applied: true, tier: "cheap")
      widget.enliterator_claims.create!(key: "k", value: "v", status: "draft", tier: "cheap", visit: v)
      result = Enliterator::Audit.sample(1)
      expect(result[:claims].size).to eq(1)   # the ORDER BY evaluates; no digests ⇒ uniform false
    end
  end

  describe "75.6 — an identical re-emission is a survival, not a change" do
    it "UPDATE with the identical value NOOPs — no re-mint, authority not refreshed" do
      tend!([ { "key" => "summary", "value" => "the same take" } ])
      original = widget.enliterator_claims.live.find_by(key: "summary")

      visit = tend!([ { "key" => "summary", "value" => "the same take", "op" => "UPDATE" } ])
      expect(visit.reconciliation["noop"]).to include("summary")
      live = widget.enliterator_claims.live.where(key: "summary").to_a
      expect(live).to eq([ original ])
      expect(original.reload.superseded_by_id).to be_nil
    end

    it "a genuinely different value still supersedes as ever" do
      tend!([ { "key" => "summary", "value" => "first take" } ])
      original = widget.enliterator_claims.live.find_by(key: "summary")
      visit = tend!([ { "key" => "summary", "value" => "better take", "op" => "UPDATE" } ])
      expect(visit.reconciliation["updated"]).to include("summary")
      expect(original.reload.superseded_by_id).to be_present
    end
  end

  describe "the cleanup rider — Claim.examinable, the one definition" do
    it "candidate_scope and the census compose from it (equivalence pinned)" do
      v = widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
      ok     = widget.enliterator_claims.create!(key: "a", value: "v", status: "draft", tier: "cheap", visit: v)
      locked = widget.enliterator_claims.create!(key: "b", value: "v", status: "verified", locked: true, visit: v)
      host   = widget.enliterator_claims.create!(key: "c", value: "v", status: "verified")

      expect(Enliterator::Claim.examinable).to include(ok)
      expect(Enliterator::Claim.examinable).not_to include(locked, host)
      expect(Enliterator::Audit.candidate_scope).to include(ok)
    end
  end

  describe "the MCP claim card" do
    it "carries warrant_stale only when audit_warrant is on AND the answer is knowable" do
      prior = Enliterator.configuration.audit_warrant
      tend!([ { "key" => "summary", "value" => "a take" } ])
      claim = widget.enliterator_claims.live.find_by(key: "summary")

      Enliterator.configuration.audit_warrant = nil
      expect(Enliterator::Mcp::Tool.new.send(:claim_card, claim)).not_to have_key(:warrant_stale)

      Enliterator.configuration.audit_warrant = true
      card = Enliterator::Mcp::Tool.new.send(:claim_card, claim)
      expect(card[:warrant_stale]).to be(false)    # knowable and fresh
    ensure
      Enliterator.configuration.audit_warrant = prior
    end
  end
end
