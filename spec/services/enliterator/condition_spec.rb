# frozen_string_literal: true

require "rails_helper"

# v0.17 — the collection shelf-reads itself. Probes are host-registered,
# survey-cadenced (never per-tend), and the rollup decides tendability:
# only a gates_tending failure pulls a record from circulation.
RSpec.describe Enliterator::Condition do
  let(:widget) { Widget.create!(title: "T", body: "b") }

  def rollup_for(record)
    record.enliterator_measures.find_by(name: "condition")
  end

  describe ".register (the namespace contract)" do
    it "validates probe names and reserves the rollup namespace" do
      expect { described_class.register("Bad Name") {} }.to raise_error(ArgumentError, /snake_case/)
      expect { described_class.register(:condition) {} }.to raise_error(ArgumentError, /reserved/)
      expect { described_class.register(:condition_extra) {} }.to raise_error(ArgumentError, /reserved/)
      expect(described_class.register(:availability) {}).to eq(:availability)
    end

    it "Measures.register refuses the condition namespace — a per-tend measure would clobber the survey" do
      expect { Enliterator::Measures.register(:condition) {} }
        .to raise_error(ArgumentError, /reserved for the condition survey/)
      expect { Enliterator::Measures.register(:condition_availability) {} }
        .to raise_error(ArgumentError, /reserved/)
    end
  end

  describe ".survey!" do
    it "no-ops loudly with no probes registered" do
      expect(described_class.survey!(widget)).to be_nil
      expect(widget.enliterator_measures.count).to eq(0)
    end

    it "writes per-probe rows + the rollup; all-ok = sound 1.0, no signature, no claim" do
      described_class.register(:availability) { |_r| { ok: true } }
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: true } }

      verdict = described_class.survey!(widget)
      expect(verdict[:band]).to eq(:sound)
      expect(widget.enliterator_measures.pluck(:name))
        .to contain_exactly("condition_availability", "condition_legibility", "condition")
      expect(rollup_for(widget).score).to eq(1.0)
      expect(rollup_for(widget).signals["signature"]).to be_nil
      expect(widget.enliterator_claims.live.find_by(key: "source_status")).to be_nil
    end

    it "NO short-circuit: a dead link with readable text is DEGRADED (0.5) — still tendable" do
      described_class.register(:availability) do |_r|
        { ok: false, code: "url_dead", note: "link unreachable",
          remediation: "supply a replacement URL or upload the PDF" }
      end
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: true } }

      verdict = described_class.survey!(widget)
      expect(verdict[:band]).to eq(:degraded)
      expect(rollup_for(widget).score).to eq(0.5)
      expect(rollup_for(widget).signals["signature"]).to eq("availability:url_dead")
      # Default claim scope is :untendable — degraded gets NO catalog note.
      expect(widget.enliterator_claims.live.find_by(key: "source_status")).to be_nil
    end

    it "a gates_tending failure is UNTENDABLE (0.0) and asserts the locked source_status claim" do
      described_class.register(:availability) { |_r| { ok: false, code: "url_dead" } }
      described_class.register(:legibility, gates_tending: true) do |_r|
        { ok: false, code: "no_text", note: "no usable text" }
      end

      verdict = described_class.survey!(widget)
      expect(verdict[:band]).to eq(:untendable)
      expect(rollup_for(widget).score).to eq(0.0)
      expect(verdict[:signature]).to eq("availability:url_dead+legibility:no_text")

      claim = widget.enliterator_claims.live.find_by(key: "source_status")
      expect(claim).to be_present
      expect(claim.locked).to be(true)
      expect(claim.value).to include("untendable").and include("no usable text")
    end

    it "retracts the claim when the record recovers — resolution is measured, not asserted" do
      described_class.register(:legibility, gates_tending: true) { |r| { ok: r.body.present?, code: "no_text" } }
      blank = Widget.create!(title: "x", body: nil)
      described_class.survey!(blank)
      expect(blank.enliterator_claims.live.where(key: "source_status")).to exist

      blank.update_columns(body: "text arrived")
      described_class.survey!(blank)
      expect(blank.enliterator_claims.live.where(key: "source_status")).not_to exist
      expect(rollup_for(blank).score).to eq(1.0)
    end

    it "condition_claim_scope = :all notes degraded records too" do
      Enliterator.configuration.condition_claim_scope = :all
      described_class.register(:availability) { |_r| { ok: false, code: "url_dead", note: "link dead" } }
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: true } }

      described_class.survey!(widget)
      claim = widget.enliterator_claims.live.find_by(key: "source_status")
      expect(claim.value).to include("degraded").and include("link dead")
    end

    it "a probe ERROR is instrument failure, not record failure — nil score, excluded from rollup" do
      described_class.register(:availability) { |_r| raise "probe exploded" }
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: true } }

      verdict = described_class.survey!(widget)
      expect(verdict[:band]).to eq(:sound)                        # the error didn't condemn it
      probe = widget.enliterator_measures.find_by(name: "condition_availability")
      expect(probe.score).to be_nil
      expect(probe.signals["probe_error"]).to include("probe exploded")
      expect(rollup_for(widget).score).to eq(1.0)
    end

    it "nil return = not applicable (skipped); a failure without a code falls back coarsely" do
      described_class.register(:availability) { |_r| nil }
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: false } }

      verdict = described_class.survey!(widget)
      expect(widget.enliterator_measures.where(name: "condition_availability")).not_to exist
      expect(verdict[:signature]).to eq("legibility:failed")
    end

    it "re-surveying upserts (one row per probe, computed_at advances)" do
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: true } }
      described_class.survey!(widget)
      first = rollup_for(widget).computed_at
      described_class.survey!(widget)
      expect(widget.enliterator_measures.where(name: "condition").count).to eq(1)
      expect(rollup_for(widget).reload.computed_at).to be >= first
    end
  end

  describe ".piles" do
    it "groups live failures by signature with counts and samples, biggest first" do
      described_class.register(:availability) { |r| { ok: !r.title.start_with?("dead"), code: "url_dead" } }
      described_class.register(:legibility, gates_tending: true) { |r| { ok: r.body.present?, code: "no_text" } }

      2.times { |i| described_class.survey!(Widget.create!(title: "dead#{i}", body: "text")) }
      described_class.survey!(Widget.create!(title: "ok", body: nil))
      described_class.survey!(Widget.create!(title: "fine", body: "text"))

      piles = described_class.piles
      expect(piles.map { |p| [ p[:signature], p[:count], p[:band] ] }).to contain_exactly(
        [ "availability:url_dead", 2, "degraded" ],
        [ "legibility:no_text", 1, "untendable" ]
      )
      expect(piles.first[:samples]).to all(be_an(Array))
    end
  end

  describe ".residue (rung 4 — the tending loop as the instrument)" do
    def visit!(record, at: 2.days.ago)
      record.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true,
                                        tier: "cheap", created_at: at, updated_at: at, started_at: at)
    end

    before do
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: true } }
    end

    it "finds sound, repeatedly-read records with ZERO engine-derived claims" do
      lost = Widget.create!(title: "lost", body: "b")
      2.times { |i| visit!(lost, at: (3 - i).days.ago) }
      described_class.survey!(lost)

      rows = described_class.residue
      expect(rows.map { |r| r[:tendable_id] }).to include(lost.id.to_s)
    end

    it "locked/host claims do NOT self-certify understanding; derived claims DO" do
      noted = Widget.create!(title: "noted", body: "b")
      2.times { |i| visit!(noted, at: (3 - i).days.ago) }
      described_class.survey!(noted)
      noted.assert_claim!(key: "source_status", value: "degraded: x")   # host claim, visit_id nil

      understood = Widget.create!(title: "understood", body: "b")
      v = visit!(understood)
      visit!(understood, at: 1.day.ago)
      understood.enliterator_claims.create!(key: "summary", value: "real understanding",
                                            visit: v, status: "draft")
      described_class.survey!(understood)

      ids = described_class.residue.map { |r| r[:tendable_id] }
      expect(ids).to include(noted.id.to_s)          # the host note isn't understanding
      expect(ids).not_to include(understood.id.to_s) # NOOP-stable with derived claims = healthy
    end

    it "excludes un-surveyed and degraded records — the pile stays pure" do
      unsurveyed = Widget.create!(title: "u", body: "b")
      2.times { |i| visit!(unsurveyed, at: (3 - i).days.ago) }

      expect(described_class.residue.map { |r| r[:tendable_id] }).not_to include(unsurveyed.id.to_s)
    end
  end

  describe ".survey_due" do
    it "never-surveyed first, then stalest" do
      described_class.register(:legibility, gates_tending: true) { |_r| { ok: true } }
      old = Widget.create!(title: "old", body: "b")
      described_class.survey!(old)
      old.enliterator_measures.update_all(computed_at: 10.days.ago)
      fresh_surveyed = Widget.create!(title: "fresh", body: "b")
      described_class.survey!(fresh_surveyed)
      never = Widget.create!(title: "never", body: "b")

      due = described_class.survey_due(limit: 2)
      expect(due.first.id).to eq(never.id)       # never-surveyed first
      expect(due.second.id).to eq(old.id)        # then stalest
    end
  end
end
