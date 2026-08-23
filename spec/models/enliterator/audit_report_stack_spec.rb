# frozen_string_literal: true

require "rails_helper"

# v0.72.3 — weighted + live companions on the accuracy report, structural n-floor.
#
# The pooled per-cell numbers are the PROCESS record and stay byte-untouched
# (audits never age out; re-tending cannot launder the number). The new keys are
# additive: population, live_decided, live_supported_rate (floored on ITS OWN
# denominator), insufficient. Rollups are a COMPANION method, never appended
# rows — every consumer iterates accuracy rows as cells.
RSpec.describe "Enliterator::Audit report stack (v0.72.3)" do
  def visit!(record, facet: "summary", tier: "cheap")
    record.enliterator_visits.create!(facet: facet, status: "succeeded", applied: true, tier: tier)
  end

  def claim!(record, key:, value: "v", facet: "summary", tier: "cheap")
    record.enliterator_claims.create!(key: key, value: value, status: "draft",
                                      tier: tier, visit: visit!(record, facet: facet, tier: tier))
  end

  def audit!(claim, verdict:, source: "examiner")
    Enliterator::Audit.create!(claim: claim, verdict: verdict, source: source)
  end

  let(:widget) { Widget.create!(title: "w", body: "b") }

  describe "the additive row keys" do
    it "keeps the v0.18 supported_rate VALUE on a tiny cell — the floor never touches the old key" do
      audit!(claim!(widget, key: "k"), verdict: "contradicted")
      cell = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(cell[:supported_rate]).to eq(0.0)      # decided=1, published as ever
      expect(cell[:insufficient]).to be(true)        # ...and badged on the NEW key
    end

    it "reports the cell's live claim population — audited or not" do
      audit!(claim!(widget, key: "a"), verdict: "supported")
      claim!(widget, key: "b")   # never audited, still population
      cell = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(cell[:population]).to eq(2)
    end

    it "floors live_supported_rate on the LIVE denominator, not the pooled one" do
      # 30 decided audits (pooled clears the floor), then supersede all but 4 —
      # the remediation scenario: pooled n stays 30, live n collapses to 4.
      claims = 30.times.map { |i| claim!(widget, key: "k#{i}") }
      claims.each { |c| audit!(c, verdict: "supported") }
      claims.first(26).each do |c|
        repl = widget.enliterator_claims.create!(key: c.key, value: "newer", status: "draft",
                                                 tier: "cheap", visit: c.visit)
        c.supersede!(repl)
      end

      cell = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(cell[:insufficient]).to be(false)        # pooled decided = 30
      expect(cell[:live_decided]).to eq(4)
      expect(cell[:live_supported_rate]).to be_nil    # 4 < 30 on ITS OWN denominator
      expect(cell[:supported_rate]).to eq(1.0)        # process record, untouched
    end

    it "shows the live rate MOVING after a remediation while the pooled rate honestly does not" do
      good = 30.times.map { |i| claim!(widget, key: "g#{i}") }
      good.each { |c| audit!(c, verdict: "supported") }
      bad = 30.times.map { |i| claim!(widget, key: "b#{i}") }
      bad.each { |c| audit!(c, verdict: "contradicted") }

      before = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(before[:supported_rate]).to eq(0.5)
      expect(before[:live_supported_rate]).to eq(0.5)

      bad.each do |c|
        repl = widget.enliterator_claims.create!(key: c.key, value: "fixed", status: "draft",
                                                 tier: "cheap", visit: c.visit)
        c.supersede!(repl)
      end

      after = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(after[:supported_rate]).to eq(0.5)         # pooled: the process record
      expect(after[:live_supported_rate]).to eq(1.0)    # live: the remediation shows
      expect(after[:live_decided]).to eq(30)
    end
  end

  describe ".accuracy_rollups (companion method, never appended rows)" do
    it "returns per-facet rollups keyed by facet — accuracy rows stay pure cells" do
      audit!(claim!(widget, key: "k"), verdict: "supported")
      rows = Enliterator::Audit.accuracy
      expect(rows.map { |r| r[:facet] }).to all(be_a(String))
      rollups = Enliterator::Audit.accuracy_rollups(rows)
      expect(rollups).to have_key("summary")
      expect(rollups["summary"]).to include(:pooled_rate, :weighted_rate, :live_rate,
                                            :insufficient_cells, :coverage)
    end

    it "weights cells by POPULATION, admits by the floor, and reports coverage honestly" do
      # Cell A (cheap): population 40, all supported, 30 audited — admitted.
      40.times { |i| claim!(widget, key: "a#{i}", tier: "cheap") }
      widget.enliterator_claims.where("key LIKE 'a%'").order(:created_at).limit(30)
            .each { |c| audit!(c, verdict: "supported") }
      # Cell B (quality): population 10, 30 audited all contradicted (audits of
      # now-superseded claims keep the pooled cell big while population is small).
      backing = 30.times.map { |i| claim!(widget, key: "q#{i}", tier: "quality") }
      backing.each { |c| audit!(c, verdict: "contradicted") }
      backing.first(20).each do |c|
        repl = widget.enliterator_claims.create!(key: c.key, value: "n", status: "draft",
                                                 tier: "quality", visit: c.visit)
        c.supersede!(repl)
      end
      # An unaudited cell whose population must show up ONLY in coverage's denominator:
      claim!(widget, key: "z", tier: "unknown_tier")

      rows    = Enliterator::Audit.accuracy
      rollup  = Enliterator::Audit.accuracy_rollups(rows)["summary"]

      # pooled: 30 supported + 30 contradicted = .5
      expect(rollup[:pooled_rate]).to eq(0.5)
      # weighted: cheap rate 1.0 × pop 40, quality rate 0.0 × pop 30 → 40/70
      cheap_pop   = rows.find { |r| r[:tier] == "cheap" }[:population]
      quality_pop = rows.find { |r| r[:tier] == "quality" }[:population]
      expect(rollup[:weighted_rate]).to eq(((1.0 * cheap_pop) / (cheap_pop + quality_pop)).round(3))
      # coverage: audited cells' population over the whole facet's (the z-cell drops out of the numerator)
      total = cheap_pop + quality_pop + 1
      expect(rollup[:coverage]).to eq(((cheap_pop + quality_pop).to_f / total).round(3))
      # Both audited cells clear the pooled floor (audits survive supersession);
      # the z-cell has no audits → no ROW at all, so it can only ever appear in
      # coverage's denominator, never as an insufficient cell.
      expect(rollup[:insufficient_cells]).to eq(0)
    end
  end
end
