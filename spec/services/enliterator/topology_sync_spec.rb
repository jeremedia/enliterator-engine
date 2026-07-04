# frozen_string_literal: true

require "rails_helper"

# v0.56 — Topology::Sync: the derived Context as a machine-owned VIEW of the
# host grouping (create / adopt / follow / reconcile holdings / sweep orphans).
RSpec.describe Enliterator::Topology::Sync do
  let(:topology) do
    Enliterator::Topology.new do
      whole "Book", members: "Widget", foreign_key: :book_id,
            context_key: :slug, context_name: :title
    end
  end

  def run!(fail_soft: false)
    described_class.run!(topology: topology, fail_soft: fail_soft)
  end

  let!(:book)   { Book.create!(slug: "the-smaller-infinity", title: "The Smaller Infinity") }
  let!(:w_in)   { Widget.create!(title: "ch 1", body: "x", book_id: book.id) }
  let!(:w_also) { Widget.create!(title: "ch 2 (draft)", body: "y", book_id: book.id) }
  let!(:w_out)  { Widget.create!(title: "loose doc", body: "z") }

  it "creates one derived context per whole with the HOLDINGS as members (every FK member; non-members excluded)" do
    result = run!
    ctx = Enliterator::Context.find_by(key: "the-smaller-infinity")
    expect(ctx.derived_from_type).to eq("Book")
    expect(ctx.derived_from_id).to eq(book.id.to_s)
    expect(ctx.name).to eq("The Smaller Infinity")
    expect(ctx.memberships.pluck(:member_id)).to contain_exactly(w_in.id.to_s, w_also.id.to_s)
    expect(result.created).to eq(1)
    expect(result.members_added).to eq(2)
  end

  it "is idempotent — a second run reports zero changes" do
    run!
    second = run!
    expect(second.created).to eq(0)
    expect(second.adopted).to eq(0)
    expect(second.members_added).to eq(0)
    expect(second.members_removed).to eq(0)
  end

  it "ADOPTS a hand-curated context with the same key, stamping it and reconciling its membership" do
    hand = Enliterator::Context.create!(key: "the-smaller-infinity", name: "Old name")
    w_in.place_in_context!(hand)   # partial hand seeding (the spine TSI shape)

    result = run!
    expect(result.adopted).to eq(1)
    expect(result.created).to eq(0)
    hand.reload
    expect(hand.derived_from_type).to eq("Book")
    expect(hand.name).to eq("The Smaller Infinity")
    expect(hand.memberships.pluck(:member_id)).to contain_exactly(w_in.id.to_s, w_also.id.to_s)
    expect(result.lines.join).to include("ADOPTED")
  end

  it "raises on a key collision across DIFFERENT wholes, naming both (never auto-suffixes)" do
    run!
    Book.create!(slug: "the-smaller-infinity", title: "Impostor")
    expect { run! }.to raise_error(Enliterator::ConfigurationError, /not unique across wholes/)
  end

  it "raises on a key that violates the Context key format (never normalizes)" do
    book.update!(slug: "Bad_Slug")
    expect { run! }.to raise_error(Enliterator::ConfigurationError, /required format/)
  end

  it "key and name FOLLOW the whole (the grouping is the source of truth)" do
    run!
    book.update!(slug: "renamed-book", title: "Renamed")
    result = run!
    ctx = Enliterator::Context.find_by(derived_from_type: "Book", derived_from_id: book.id.to_s)
    expect(ctx.key).to eq("renamed-book")
    expect(ctx.name).to eq("Renamed")
    expect(result.renamed).to eq(1)
  end

  it "REFUSES to rename a key that carries declared policy facets (the policy joins by key)" do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "abs" }
        context "the-smaller-infinity" do
          facet :directive, tier: "cheap", terms: { d: "d" }
        end
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
    run!
    book.update!(slug: "renamed-book")
    expect { run! }.to raise_error(Enliterator::ConfigurationError, /refusing to rename/)
  end

  it "removes stale declared-type memberships (a member that left the grouping; also the tombstone sweep)" do
    run!
    ctx = Enliterator::Context.find_by(key: "the-smaller-infinity")
    w_also.update!(book_id: nil)
    result = run!
    expect(result.members_removed).to eq(1)
    expect(ctx.memberships.pluck(:member_id)).to contain_exactly(w_in.id.to_s)
  end

  it "hand-placed members of an UNDECLARED type survive (the machine owns what it declared, nothing more)" do
    run!
    ctx = Enliterator::Context.find_by(key: "the-smaller-infinity")
    pinned = Book.create!(slug: "curators-pin", title: "Pinned")   # Book is real but NOT the declared member type
    Enliterator::ContextMembership.create!(context: ctx, member: pinned)
    result = run!
    expect(result.members_removed).to eq(0)
    expect(ctx.memberships.where(member_type: "Book").count).to eq(1)
  end

  it "sweeps an orphan derived context when its whole is destroyed and nothing references it" do
    run!
    book.destroy!
    result = run!
    expect(result.orphans_removed).to eq(1)
    expect(Enliterator::Context.find_by(key: "the-smaller-infinity")).to be_nil
  end

  it "KEEPS a referenced orphan derived context, with a warning (claims could scope to it one day)" do
    run!
    ctx = Enliterator::Context.find_by(key: "the-smaller-infinity")
    w_out.assert_claim!(key: "note", value: "v", context: ctx)
    book.destroy!
    result = run!
    expect(result.orphans_removed).to eq(0)
    expect(result.warnings.join).to include("kept")
    expect(Enliterator::Context.exists?(ctx.id)).to be true
  end

  it "warns when a declared whole is a Tendable but not in synthesized_tendables (the pacemaker would schedule it)" do
    widget_as_whole = Enliterator::Topology.new do
      whole "Widget", members: "Book", foreign_key: :widget_id, context_key: :slug, context_name: :title
    end
    result = described_class.run!(topology: widget_as_whole, fail_soft: true)
    expect(result.warnings.join).to include("not in config.synthesized_tendables")

    Enliterator.configure { |c| c.synthesized_tendables = %w[Widget] }
    masked = described_class.run!(topology: widget_as_whole, fail_soft: true)
    expect(masked.warnings.join).not_to include("synthesized_tendables")
  end

  it "fail_soft contains a bad whole to a warning and keeps syncing the rest (one bad slug never halts the collection)" do
    good = Book.create!(slug: "healthy-book", title: "Healthy")
    Widget.create!(title: "hb ch", body: "x", book_id: good.id)
    book.update!(slug: "Bad_Slug")

    result = run!(fail_soft: true)
    expect(result.warnings.join).to include("required format")
    expect(Enliterator::Context.find_by(key: "healthy-book")).to be_present
  end

  describe "the heartbeat step (Heartbeat#sync_topology!)" do
    let(:beat) do
      Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 1000,
                                     started_at: Time.current, planned: { "items" => [] })
    end

    it "with a topology declared: pulses the topology phase and derives the contexts, warnings into the ledger channel" do
      Enliterator.configure { |c| c.topology = topology }
      warnings = []
      beat.send(:sync_topology!, warnings)

      expect(beat.reload.phase).to eq("topology")
      expect(Enliterator::Context.find_by(key: "the-smaller-infinity")).to be_present
      expect(warnings).to eq([])
    end

    it "with NO topology: never pulses — the phase trace stays byte-identical for non-adopters" do
      before_phase = beat.reload.phase
      warnings = []
      beat.send(:sync_topology!, warnings)

      expect(beat.reload.phase).to eq(before_phase)
      expect(warnings).to eq([])
      expect(Enliterator::Context.count).to eq(0)
    end

    it "a sync error becomes a run warning, never a halted cycle (fail-soft)" do
      book.update!(slug: "Bad_Slug")
      Enliterator.configure { |c| c.topology = topology }
      warnings = []
      expect { beat.send(:sync_topology!, warnings) }.not_to raise_error
      expect(warnings.join).to include("required format")
    end
  end
end
