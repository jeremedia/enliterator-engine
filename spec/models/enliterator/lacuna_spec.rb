require "rails_helper"

# v0.46: the Lacuna — a record-level known-unknown. Opened when a required term
# comes back unmet during tending, refreshed each beat it stays missing, closed
# when a later visit supplies the value. The negative space of a claim.
RSpec.describe Enliterator::Lacuna do
  let(:widget) { Widget.create!(title: "T-#{SecureRandom.hex(3)}", body: "b") }
  let(:visit)  { widget.enliterator_visits.create!(facet: "authorship", status: "succeeded", applied: true, tier: "cheap") }

  def open_for(key, **opts)
    described_class.open_or_refresh(tendable: widget, facet: "authorship", key: key, visit: visit, **opts)
  end

  describe ".open_or_refresh" do
    it "opens a new open lacuna with detections 1 and the detecting visit" do
      lac = open_for("authored_by")
      expect(lac).to be_persisted
      expect(lac.status).to eq("open")
      expect(lac.detections).to eq(1)
      expect(lac.detected_in_visit_id).to eq(visit.id)
      expect(lac.last_detected_at).to be_present
    end

    it "defaults an absent or unknown diagnosis to undiagnosed (never raises, never stores off-enum)" do
      expect(open_for("authored_by").diagnosis).to eq("undiagnosed")
      expect(open_for("advisor", diagnosis: "garbled_nonsense").diagnosis).to eq("undiagnosed")
    end

    it "keeps a substantive diagnosis when given one" do
      expect(open_for("authored_by", diagnosis: "defective_surrogate").diagnosis).to eq("defective_surrogate")
    end

    it "refreshes (not duplicates) the same tuple — bumps detections, keeps one open row" do
      open_for("authored_by")
      lac = open_for("authored_by")
      expect(described_class.open.where(tendable: widget, facet: "authorship", key: "authored_by").count).to eq(1)
      expect(lac.detections).to eq(2)
    end

    it "preserves a prior substantive diagnosis across an undiagnosed re-detection" do
      open_for("authored_by", diagnosis: "defective_surrogate")
      lac = open_for("authored_by") # no diagnosis this beat
      expect(lac.diagnosis).to eq("defective_surrogate")
    end

    it "dedups the NULL (root) context via the partial unique index (one open row)" do
      # context: nil on both → nulls_not_distinct means the unique index still dedups
      open_for("authored_by")
      open_for("authored_by")
      expect(described_class.where(tendable: widget, key: "authored_by", context_id: nil).count).to eq(1)
    end
  end

  describe "#close!" do
    it "closes the lacuna with reason and the closing visit" do
      lac    = open_for("authored_by")
      closer = widget.enliterator_visits.create!(facet: "authorship", status: "succeeded", applied: true, tier: "cheap")
      lac.close!(by_visit: closer, reason: "supplied")
      lac.reload
      expect(lac.status).to eq("closed")
      expect(lac.closed_reason).to eq("supplied")
      expect(lac.closed_by_visit_id).to eq(closer.id)
    end

    it "frees the tuple — a later open_or_refresh opens a NEW open lacuna (closed + open coexist)" do
      lac = open_for("authored_by")
      lac.close!(by_visit: visit)
      reopened = open_for("authored_by")
      expect(reopened.id).not_to eq(lac.id)
      expect(reopened.status).to eq("open")
      expect(described_class.where(tendable: widget, key: "authored_by").count).to eq(2)
    end
  end

  describe "scope :open" do
    it "returns only open lacunae" do
      a = open_for("authored_by")
      b = open_for("advisor")
      b.close!(by_visit: visit)
      expect(described_class.open).to include(a)
      expect(described_class.open).not_to include(b.reload)
    end
  end
end
