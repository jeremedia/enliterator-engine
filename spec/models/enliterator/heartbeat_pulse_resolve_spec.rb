# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Enliterator::Heartbeat::Pulse.resolve (v-next)" do
  describe "Planner#estimate" do
    it "returns a positive per-facet token estimate" do
      est = Enliterator::Heartbeat::Planner.new.estimate("summary")
      expect(est).to be_a(Integer)
      expect(est).to be > 0
    end
  end

  # A book context declaring one scheduled facet, so item counts are exact.
  let(:book) { Enliterator::Context.create!(key: "the-smaller-infinity", name: "TSI") }

  def one_facet_policy!
    Enliterator.configure do |c|
      c.tending_facets = []
      c.staffing = Enliterator::Staffing::Policy.new do
        context "the-smaller-infinity" do
          facet :significance, tier: "cheap", terms: { note: "A note." }
        end
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
  end

  # A member widget whose text was tended `tended_ago` and edited `edited_ago`.
  def member!(title:, tended_ago:, edited_ago:)
    w = Widget.create!(title: title, body: "b")
    w.place_in_context!(book)
    if tended_ago
      Enliterator::Visit.create!(tendable: w, facet: "significance", context: book,
                                 tier: "cheap", status: "succeeded", applied: true,
                                 started_at: tended_ago)
    end
    w.update_columns(updated_at: edited_ago)
    w
  end

  # Install the policy in a group `before` — NOT an `around` pre-block. The suite's
  # global `config.before(:each) { Enliterator.reset_configuration! }` (rails_helper)
  # runs INSIDE example.run, after any around pre-code, so config set in the around
  # is wiped before the body. A group before(:each) runs AFTER the global one, so it
  # survives.
  before { one_facet_policy! }

  it "resolves CONTEXT to members × declared facets" do
    a = member!(title: "a", tended_ago: nil, edited_ago: 1.day.ago)
    b = member!(title: "b", tended_ago: nil, edited_ago: 1.day.ago)
    plan = Enliterator::Heartbeat::Pulse.resolve(context: "the-smaller-infinity")
    tuples = plan.items.map { |i| [ i.tendable_type, i.tendable_id, i.facet ] }
    expect(tuples).to contain_exactly(
      [ "Widget", a.id.to_s, "significance" ],
      [ "Widget", b.id.to_s, "significance" ]
    )
    expect(plan.items).to all(have_attributes(reason: "pulse"))
    expect(plan.items.first.est_tokens).to be > 0
  end

  it "STALE keeps only source-moved, previously-tended members" do
    stale   = member!(title: "stale",   tended_ago: 5.days.ago, edited_ago: 1.day.ago)
    fresh   = member!(title: "fresh",   tended_ago: 1.day.ago,  edited_ago: 5.days.ago)
    untened = member!(title: "new",     tended_ago: nil,        edited_ago: 1.day.ago)
    plan = Enliterator::Heartbeat::Pulse.resolve(stale: true, context: "the-smaller-infinity")
    ids = plan.items.map(&:tendable_id)
    expect(ids).to eq([ stale.id.to_s ])
    expect(ids).not_to include(fresh.id.to_s, untened.id.to_s)
  end

  it "resolves explicit targets via config.pulse_resolver" do
    a = member!(title: "combustion-edge", tended_ago: nil, edited_ago: 1.day.ago)
    Enliterator.configuration.pulse_resolver = ->(token) { Widget.find_by(title: token) }
    plan = Enliterator::Heartbeat::Pulse.resolve(targets: [ "combustion-edge" ])
    expect(plan.items.map(&:tendable_id)).to eq([ a.id.to_s ])
  end

  it "unions targets, stale, and context without duplicates" do
    a = member!(title: "a", tended_ago: 5.days.ago, edited_ago: 1.day.ago)
    Enliterator.configuration.pulse_resolver = ->(token) { Widget.find_by(title: token) }
    plan = Enliterator::Heartbeat::Pulse.resolve(
      targets: [ "a" ], stale: true, context: "the-smaller-infinity"
    )
    expect(plan.items.map(&:tendable_id)).to eq([ a.id.to_s ])
  end

  it "returns an empty plan for an existing context with no members" do
    book # create the (empty) context — a MISSING context raises; an empty one is the no-op path
    plan = Enliterator::Heartbeat::Pulse.resolve(context: "the-smaller-infinity")
    expect(plan.items).to be_empty
  end

  it "raises on a named context that does not exist (a typo is loud, not silently empty)" do
    expect { Enliterator::Heartbeat::Pulse.resolve(context: "no-such-book") }
      .to raise_error(ArgumentError, /no context with key/)
  end

  it "refuses collection-wide stale with no scope (deferred, not a full scan)" do
    expect { Enliterator::Heartbeat::Pulse.resolve(stale: true) }
      .to raise_error(ArgumentError, /STALE needs a CONTEXT/)
  end

  it "refuses a context larger than the member cap (bulk is the beat's job)" do
    member!(title: "a", tended_ago: nil, edited_ago: 1.day.ago)
    member!(title: "b", tended_ago: nil, edited_ago: 1.day.ago)
    stub_const("Enliterator::Heartbeat::Pulse::CONTEXT_MEMBER_CAP", 1)
    expect { Enliterator::Heartbeat::Pulse.resolve(context: "the-smaller-infinity") }
      .to raise_error(ArgumentError, /bounded targets/)
  end

  it "raises on an explicit target that does not resolve (a misdirected pulse is loud)" do
    Enliterator.configuration.pulse_resolver = ->(token) { Widget.find_by(title: token) }
    expect { Enliterator::Heartbeat::Pulse.resolve(targets: [ "no-such-chapter" ]) }
      .to raise_error(ArgumentError, /no record for target/)
  end
end
