require "rails_helper"

# v0.45: name authority control — the read-time resolver from a name VALUE to its
# canonical (preferred) form. Empty table ⇒ identity ⇒ byte-identical.
RSpec.describe Enliterator::NameAuthority do
  it "is the identity when the table is empty (byte-identical guarantee)" do
    expect(described_class.canonical_for("Jordan Avery")).to eq("Jordan Avery")
    expect(described_class.map_for).to eq({})
  end

  context "with authority records" do
    let!(:ctx) { Enliterator::Context.create!(key: "chds-theses", name: "CHDS Theses") }
    let!(:avery) do
      described_class.create!(
        canonical: "Jordan Avery",
        variants: [ "Jordan L. Avery", "Jordan L. Avery (contractor)" ],
        context_id: ctx.id, status: "auto")
    end

    it "canonical_for resolves a variant to the preferred form, in context" do
      expect(described_class.canonical_for("Jordan L. Avery", context: ctx)).to eq("Jordan Avery")
      expect(described_class.canonical_for("Jordan L. Avery (contractor)", context: ctx)).to eq("Jordan Avery")
      expect(described_class.canonical_for("Jordan Avery", context: ctx)).to eq("Jordan Avery")
    end

    it "leaves an unmapped value unchanged" do
      expect(described_class.canonical_for("Casey T. Reed", context: ctx)).to eq("Casey T. Reed")
    end

    it "variants_for expands a canonical to all its see-from forms (incl. itself)" do
      expect(described_class.variants_for("Jordan Avery", context: ctx)).to match_array(
        [ "Jordan Avery", "Jordan L. Avery", "Jordan L. Avery (contractor)" ])
    end

    it "map_for builds {value => canonical} for the context, incl. canonical→self" do
      m = described_class.map_for(context: ctx)
      expect(m["Jordan L. Avery"]).to eq("Jordan Avery")
      expect(m["Jordan L. Avery (contractor)"]).to eq("Jordan Avery")
      expect(m["Jordan Avery"]).to eq("Jordan Avery")
    end

    it "does NOT apply held records (only auto/ratified resolve)" do
      described_class.create!(canonical: "Jordan Frey Marcus Calloway",
                              variants: [ "Jordan Frey Marcus Calloway" ], context_id: ctx.id, status: "held")
      expect(described_class.canonical_for("Jordan Frey Marcus Calloway", context: ctx)).to eq("Jordan Frey Marcus Calloway")
    end

    it "reads authorities up the context path (a root authority resolves in a child context)" do
      described_class.create!(canonical: "Jane Q. Root", variants: [ "J. Root" ], context_id: nil, status: "auto")
      expect(described_class.canonical_for("J. Root", context: ctx)).to eq("Jane Q. Root")
    end

    it "a context-scoped authority does NOT leak to an unrelated context" do
      other = Enliterator::Context.create!(key: "crs-reports", name: "CRS")
      expect(described_class.canonical_for("Jordan L. Avery", context: other)).to eq("Jordan L. Avery")
    end
  end
end
