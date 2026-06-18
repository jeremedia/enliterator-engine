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
    advise!("Jordan Avery", 3)
    advise!("Jordan L. Avery", 2)
    advise!("Jordan L. Avery (contractor)", 1)
    reconcile!

    a = auth("Jordan Avery") # most frequent, clean form is the preferred form
    expect(a).to be_present
    expect(a.status).to eq("auto")
    expect(a.variants).to include("Jordan L. Avery", "Jordan L. Avery (contractor)")
    expect(Enliterator::NameAuthority.canonical_for("Jordan L. Avery (contractor)", context: ctx)).to eq("Jordan Avery")
  end

  it "merges a middle-initial variant with the bare name (Casey T. Reed / Casey Reed)" do
    advise!("Casey T. Reed", 4)
    advise!("Casey Reed", 2)
    reconcile!
    a = auth("Casey T. Reed")
    expect(a).to be_present
    expect(a.variants).to include("Casey Reed")
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
    advise!("Mark A. Dalton", 2)
    advise!("Mark B. Dalton", 2)
    reconcile!
    held = Enliterator::NameAuthority.where(context_id: ctx.id, status: "held").flat_map(&:variants)
    expect(held).to include("Mark A. Dalton", "Mark B. Dalton")
    # held → NOT applied: resolution stays identity
    expect(Enliterator::NameAuthority.canonical_for("Mark A. Dalton", context: ctx)).to eq("Mark A. Dalton")
  end

  it "HOLDS a concatenated extraction error (a value containing two known surnames)" do
    advise!("Jordan Frey", 3)      # establishes 'Frey' as a known surname
    advise!("Marcus Calloway", 3)    # establishes 'Calloway'
    advise!("Jordan Frey Marcus Calloway", 1) # the merge-error value
    reconcile!
    rec = Enliterator::NameAuthority.where(context_id: ctx.id, status: "held").detect { |a| a.variants.include?("Jordan Frey Marcus Calloway") }
    expect(rec).to be_present
    expect(Enliterator::NameAuthority.canonical_for("Jordan Frey Marcus Calloway", context: ctx)).to eq("Jordan Frey Marcus Calloway") # not applied
  end

  it "does NOT falsely hold a clean name whose FIRST name is also a surname elsewhere" do
    advise!("Paula Foster", 2)     # establishes 'foster' as a known surname
    advise!("Foster Whitfield", 2)   # 'Foster' here is a first name — not a concatenation
    advise!("Foster J. Whitfield", 1)
    reconcile!
    expect(auth("Foster Whitfield")&.status).to eq("auto") # Whitfield variants merge, not held
    held = Enliterator::NameAuthority.where(context_id: ctx.id, status: "held").flat_map(&:variants)
    expect(held).not_to include("Foster Whitfield", "Foster J. Whitfield")
  end

  it "is idempotent: re-running yields the same authority records" do
    advise!("Jordan Avery", 3)
    advise!("Jordan L. Avery", 2)
    reconcile!
    before = Enliterator::NameAuthority.where(context_id: ctx.id).count
    reconcile!
    expect(Enliterator::NameAuthority.where(context_id: ctx.id).count).to eq(before)
    expect(auth("Jordan Avery").variants).to include("Jordan L. Avery")
  end

  it "preserves human-ratified records across a re-run" do
    Enliterator::NameAuthority.create!(canonical: "Ratified Person", variants: [ "R. Person" ],
                                       context_id: ctx.id, status: "ratified")
    advise!("Jordan Avery", 2); advise!("Jordan L. Avery", 1)
    reconcile!
    expect(Enliterator::NameAuthority.find_by(canonical: "Ratified Person", context_id: ctx.id)).to be_present
  end

  it "is a no-op when no name keys are given" do
    advise!("Jordan Avery", 2); advise!("Jordan L. Avery", 1)
    described_class.reconcile!(context: ctx, keys: [])
    expect(Enliterator::NameAuthority.where(context_id: ctx.id).count).to eq(0)
  end
end
