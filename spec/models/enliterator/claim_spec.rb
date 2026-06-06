require "rails_helper"

# Claims are PROV Entities: provenanced, reconcilable units of understanding.
# They are never edited in place. An UPDATE creates a NEW claim and supersedes the
# old one (supersede! sets status "superseded" + superseded_by), so the supersession
# chain is the provenance trail. The `current` and `live` scopes project that chain
# down to the answer that holds right now.
RSpec.describe Enliterator::Claim do
  let(:widget) { Widget.create!(title: "Acme", body: "A widget.") }

  # Build a claim attached to the dummy Widget host. Defaults give a live,
  # non-superseded "summary" claim unless overridden.
  def make_claim(key: "summary", value: "v", status: "draft", **attrs)
    described_class.create!(
      tendable: widget,
      key:      key,
      value:    value,
      status:   status,
      **attrs
    )
  end

  describe "#supersede!" do
    it "marks the old claim superseded and points it at the replacement" do
      old = make_claim(value: "first")
      new = make_claim(value: "second")

      old.supersede!(new)

      expect(old.status).to eq("superseded")
      expect(old.superseded_by).to eq(new)
      expect(old.superseded_by_id).to eq(new.id)
    end

    it "persists the supersession (survives reload)" do
      old = make_claim(value: "first")
      new = make_claim(value: "second")

      old.supersede!(new)

      reloaded = described_class.find(old.id)
      expect(reloaded.status).to eq("superseded")
      expect(reloaded.superseded_by_id).to eq(new.id)
    end

    it "supports a multi-step chain (v1 -> v2 -> v3) preserving each link" do
      v1 = make_claim(value: "v1")
      v2 = make_claim(value: "v2")
      v3 = make_claim(value: "v3")

      v1.supersede!(v2)
      v2.supersede!(v3)

      expect(v1.reload.superseded_by).to eq(v2)
      expect(v2.reload.superseded_by).to eq(v3)
      expect(v3.reload.superseded_by_id).to be_nil

      # Both earlier links are tombstoned; only the tail remains an answer.
      expect(v1.status).to eq("superseded")
      expect(v2.status).to eq("superseded")
      expect(v3.status).to eq("draft")
    end
  end

  describe ".current" do
    it "returns only claims that have not been superseded" do
      old = make_claim(value: "first")
      new = make_claim(value: "second")
      old.supersede!(new)

      expect(described_class.current).to include(new)
      expect(described_class.current).not_to include(old)
    end

    it "keeps the tail of a chain and drops every superseded link" do
      v1 = make_claim(value: "v1")
      v2 = make_claim(value: "v2")
      v3 = make_claim(value: "v3")
      v1.supersede!(v2)
      v2.supersede!(v3)

      expect(described_class.current).to contain_exactly(v3)
    end
  end

  describe ".live" do
    it "is current AND not tombstoned" do
      kept    = make_claim(key: "summary", value: "kept")
      deleted = make_claim(key: "authored_by", value: "tombstone")

      # A DELETE in the reconcile contract supersedes a claim with no replacement:
      # the row stays current (superseded_by_id nil) but status becomes superseded.
      deleted.update!(status: "superseded")

      expect(described_class.live).to include(kept)
      expect(described_class.live).not_to include(deleted)
    end

    it "excludes a superseded claim even when it still heads no chain" do
      tombstone = make_claim(status: "superseded")

      # current (superseded_by_id is nil) but not live (status superseded).
      expect(described_class.current).to include(tombstone)
      expect(described_class.live).not_to include(tombstone)
    end

    it "includes draft and verified claims" do
      draft    = make_claim(key: "a", status: "draft")
      verified = make_claim(key: "b", status: "verified")

      expect(described_class.live).to contain_exactly(draft, verified)
    end
  end

  describe "#to_state" do
    it "projects the compact prompt-context shape" do
      claim = make_claim(key: "summary", value: "hi", confidence: 0.8, status: "draft", locked: true)

      expect(claim.to_state).to eq(
        key:        "summary",
        value:      "hi",
        confidence: 0.8,
        status:     "draft",
        locked:     true
      )
    end
  end
end
