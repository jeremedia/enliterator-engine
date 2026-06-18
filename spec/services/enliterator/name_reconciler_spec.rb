require "rails_helper"

# v0.45: the deterministic, high-precision name reconciler. It clusters variant
# spellings of one advisor/author into an authority record (auto), and HOLDS the
# ambiguous (two middle initials sharing a name) and the concatenated extraction
# errors (a value containing two known surnames) for human review — it NEVER
# merges two distinct people.
RSpec.describe Enliterator::NameReconciler do
  let!(:ctx) { Enliterator::Context.create!(key: "chds-theses", name: "CHDS Theses") }

  # Create `n` theses each carrying advisor=`name` (live claim, scoped to ctx).
  def advise!(name, n = 1)
    n.times do
      w = Widget.create!(title: "T-#{SecureRandom.hex(3)}", body: "b")
      v = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
      w.enliterator_claims.create!(key: "advisor", value: name, status: "draft",
                                   confidence: 0.8, visit: v, context_id: ctx.id)
    end
  end

  def reconcile! = described_class.reconcile!(context: ctx, keys: %w[advisor])
  def auth(canonical) = Enliterator::NameAuthority.find_by(canonical: canonical, context_id: ctx.id)

  it "merges suffix / contractor / middle-initial variants into one auto authority" do
    advise!("Robert Simeral", 3)
    advise!("Robert L. Simeral", 2)
    advise!("Robert L. Simeral (contractor)", 1)
    reconcile!

    a = auth("Robert Simeral") # most frequent, clean form is the preferred form
    expect(a).to be_present
    expect(a.status).to eq("auto")
    expect(a.variants).to include("Robert L. Simeral", "Robert L. Simeral (contractor)")
    expect(Enliterator::NameAuthority.canonical_for("Robert L. Simeral (contractor)", context: ctx)).to eq("Robert Simeral")
  end

  it "merges a middle-initial variant with the bare name (Erik J. Dahl / Erik Dahl)" do
    advise!("Erik J. Dahl", 4)
    advise!("Erik Dahl", 2)
    reconcile!
    a = auth("Erik J. Dahl")
    expect(a).to be_present
    expect(a.variants).to include("Erik Dahl")
  end

  it "folds diacritic variants together" do
    advise!("Rodrigo Nieto-Gomez", 3)
    advise!("Rodrigo Nieto-Gómez", 1)
    reconcile!
    expect(Enliterator::NameAuthority.canonical_for("Rodrigo Nieto-Gómez", context: ctx)).to eq("Rodrigo Nieto-Gomez")
  end

  it "NEVER merges two distinct people sharing a surname (different first names)" do
    advise!("John Smith", 2)
    advise!("Jane Smith", 2)
    reconcile!
    expect(Enliterator::NameAuthority.where(context_id: ctx.id).pluck(:canonical)).not_to include("John Smith", "Jane Smith")
    expect(Enliterator::NameAuthority.canonical_for("John Smith", context: ctx)).to eq("John Smith") # identity, unmerged
  end

  it "HOLDS an ambiguous group: same first+last, two different middle initials" do
    advise!("John A. Cooper", 2)
    advise!("John B. Cooper", 2)
    reconcile!
    held = Enliterator::NameAuthority.where(context_id: ctx.id, status: "held").flat_map(&:variants)
    expect(held).to include("John A. Cooper", "John B. Cooper")
    # held → NOT applied: resolution stays identity
    expect(Enliterator::NameAuthority.canonical_for("John A. Cooper", context: ctx)).to eq("John A. Cooper")
  end

  it "HOLDS a concatenated extraction error (a value containing two known surnames)" do
    advise!("Robert Bach", 3)      # establishes 'Bach' as a known surname
    advise!("David Brannan", 3)    # establishes 'Brannan'
    advise!("Robert Bach David Brannan", 1) # the merge-error value
    reconcile!
    rec = Enliterator::NameAuthority.where(context_id: ctx.id, status: "held").detect { |a| a.variants.include?("Robert Bach David Brannan") }
    expect(rec).to be_present
    expect(Enliterator::NameAuthority.canonical_for("Robert Bach David Brannan", context: ctx)).to eq("Robert Bach David Brannan") # not applied
  end

  it "does NOT falsely hold a clean name whose FIRST name is also a surname elsewhere" do
    advise!("Gail Thomas", 2)     # establishes 'thomas' as a known surname
    advise!("Thomas Mackin", 2)   # 'Thomas' here is a first name — not a concatenation
    advise!("Thomas J. Mackin", 1)
    reconcile!
    expect(auth("Thomas Mackin")&.status).to eq("auto") # Mackin variants merge, not held
    held = Enliterator::NameAuthority.where(context_id: ctx.id, status: "held").flat_map(&:variants)
    expect(held).not_to include("Thomas Mackin", "Thomas J. Mackin")
  end

  it "is idempotent: re-running yields the same authority records" do
    advise!("Robert Simeral", 3)
    advise!("Robert L. Simeral", 2)
    reconcile!
    before = Enliterator::NameAuthority.where(context_id: ctx.id).count
    reconcile!
    expect(Enliterator::NameAuthority.where(context_id: ctx.id).count).to eq(before)
    expect(auth("Robert Simeral").variants).to include("Robert L. Simeral")
  end

  it "preserves human-ratified records across a re-run" do
    Enliterator::NameAuthority.create!(canonical: "Ratified Person", variants: [ "R. Person" ],
                                       context_id: ctx.id, status: "ratified")
    advise!("Robert Simeral", 2); advise!("Robert L. Simeral", 1)
    reconcile!
    expect(Enliterator::NameAuthority.find_by(canonical: "Ratified Person", context_id: ctx.id)).to be_present
  end

  it "is a no-op when no name keys are given" do
    advise!("Robert Simeral", 2); advise!("Robert L. Simeral", 1)
    described_class.reconcile!(context: ctx, keys: [])
    expect(Enliterator::NameAuthority.where(context_id: ctx.id).count).to eq(0)
  end
end
