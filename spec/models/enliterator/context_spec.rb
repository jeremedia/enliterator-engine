# frozen_string_literal: true

require "rails_helper"

# v0.13 — the Context tree (nested enliterated collections) + M2M membership.
RSpec.describe Enliterator::Context do
  let(:root) { described_class.create!(key: "hsdl", name: "HSDL") }
  let(:eo)   { described_class.create!(key: "executive-orders", name: "Executive Orders", parent: root) }

  it "is an ancestry tree: path_keys runs root → self" do
    expect(eo.path_keys).to eq(%w[hsdl executive-orders])
    expect(root.path_keys).to eq(%w[hsdl])
    expect(eo.parent).to eq(root)
    expect(root.children).to include(eo)
  end

  it "scope_ids = NULL (the root scope) + ancestors + self — the cumulative-read scope" do
    expect(eo.scope_ids).to eq([ nil, root.id, eo.id ])
  end

  it "requires a unique lowercase-slug key" do
    root # materialize the original
    expect { described_class.create!(key: "Bad Key!", name: "x") }
      .to raise_error(ActiveRecord::RecordInvalid, /slug/)
    expect { described_class.create!(key: "hsdl", name: "dupe") }
      .to raise_error(ActiveRecord::RecordInvalid, /taken/)
  end

  describe "membership (M2M through ContextMembership)" do
    let(:widget) { Widget.create!(title: "EO 14067", body: "directive text") }

    it "place_in_context! is idempotent and an item can live in many contexts" do
      list = described_class.create!(key: "election-security", name: "Election Security", parent: root)
      widget.place_in_context!(eo)
      widget.place_in_context!(eo)   # no dupe
      widget.place_in_context!(list)
      expect(widget.enliterator_contexts).to contain_exactly(eo, list)
      expect(eo.memberships.count).to eq(1)
    end
  end
end
