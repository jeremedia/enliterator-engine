require "rails_helper"

# v0.45: name authority control — the read-time resolver from a name VALUE to its
# canonical (preferred) form. Empty table ⇒ identity ⇒ byte-identical.
RSpec.describe Enliterator::NameAuthority do
  it "is the identity when the table is empty (byte-identical guarantee)" do
    expect(described_class.canonical_for("Robert Simeral")).to eq("Robert Simeral")
    expect(described_class.map_for).to eq({})
  end

  context "with authority records" do
    let!(:ctx) { Enliterator::Context.create!(key: "chds-theses", name: "CHDS Theses") }
    let!(:simeral) do
      described_class.create!(
        canonical: "Robert Simeral",
        variants: [ "Robert L. Simeral", "Robert L. Simeral (contractor)" ],
        context_id: ctx.id, status: "auto")
    end

    it "canonical_for resolves a variant to the preferred form, in context" do
      expect(described_class.canonical_for("Robert L. Simeral", context: ctx)).to eq("Robert Simeral")
      expect(described_class.canonical_for("Robert L. Simeral (contractor)", context: ctx)).to eq("Robert Simeral")
      expect(described_class.canonical_for("Robert Simeral", context: ctx)).to eq("Robert Simeral")
    end

    it "leaves an unmapped value unchanged" do
      expect(described_class.canonical_for("Erik J. Dahl", context: ctx)).to eq("Erik J. Dahl")
    end

    it "variants_for expands a canonical to all its see-from forms (incl. itself)" do
      expect(described_class.variants_for("Robert Simeral", context: ctx)).to match_array(
        [ "Robert Simeral", "Robert L. Simeral", "Robert L. Simeral (contractor)" ])
    end

    it "map_for builds {value => canonical} for the context, incl. canonical→self" do
      m = described_class.map_for(context: ctx)
      expect(m["Robert L. Simeral"]).to eq("Robert Simeral")
      expect(m["Robert L. Simeral (contractor)"]).to eq("Robert Simeral")
      expect(m["Robert Simeral"]).to eq("Robert Simeral")
    end

    it "does NOT apply held records (only auto/ratified resolve)" do
      described_class.create!(canonical: "Robert Bach David Brannan",
                              variants: [ "Robert Bach David Brannan" ], context_id: ctx.id, status: "held")
      expect(described_class.canonical_for("Robert Bach David Brannan", context: ctx)).to eq("Robert Bach David Brannan")
    end

    it "reads authorities up the context path (a root authority resolves in a child context)" do
      described_class.create!(canonical: "Jane Q. Root", variants: [ "J. Root" ], context_id: nil, status: "auto")
      expect(described_class.canonical_for("J. Root", context: ctx)).to eq("Jane Q. Root")
    end

    it "a context-scoped authority does NOT leak to an unrelated context" do
      other = Enliterator::Context.create!(key: "crs-reports", name: "CRS")
      expect(described_class.canonical_for("Robert L. Simeral", context: other)).to eq("Robert L. Simeral")
    end
  end
end
