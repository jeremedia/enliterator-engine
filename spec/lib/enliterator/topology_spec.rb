# frozen_string_literal: true

require "rails_helper"

# v0.56 — the topology declaration (the grouping/membership half of the
# shape-of-a-collection §5 declaration) + the reading-scope coherence rule.
RSpec.describe Enliterator::Topology do
  def book_topology
    described_class.new do
      whole "Book", members: "Widget", foreign_key: :book_id,
            context_key: :slug, context_name: :title
    end
  end

  describe "the whole DSL" do
    it "declares a grouping with string names, resolvable per member type" do
      topo = book_topology
      expect(topo.declares_wholes?).to be true
      decl = topo.declaration_for_member("Widget")
      expect(decl.whole_type).to eq("Book")
      expect(decl.foreign_key).to eq(:book_id)
      expect(decl.context_key).to eq(:slug)
      expect(topo.declaration_for_whole("Book")).to eq(decl)
      expect(topo.declaration_for_member("Gadget")).to be_nil
    end

    it "an empty declaration declares no wholes" do
      expect(described_class.new.declares_wholes?).to be false
    end

    it "raises on a second whole claiming the same member type (ambiguous reading scope)" do
      expect {
        described_class.new do
          whole "Book",  members: "Widget", foreign_key: :book_id, context_key: :slug, context_name: :title
          whole "Shelf", members: "Widget", foreign_key: :shelf_id, context_key: :slug, context_name: :title
        end
      }.to raise_error(Enliterator::ConfigurationError, /one whole per member type/)
    end
  end

  describe "Enliterator.reading_scope (the coherence rule as code)" do
    it "is nil by default (collection-wide, byte-identical)" do
      expect(Enliterator.reading_scope).to be_nil
    end

    it "raises on an unknown value — a misconfiguration must fail loudly, never read as collection-wide" do
      Enliterator.configure { |c| c.default_reading_scope = :collection }
      expect { Enliterator.reading_scope }
        .to raise_error(Enliterator::ConfigurationError, /must be nil .* or :whole/)
    end

    it "raises on :whole without a wholes-declaring topology (§6: the charter may only name a rung the topology declares)" do
      Enliterator.configure { |c| c.default_reading_scope = :whole }
      expect { Enliterator.reading_scope }
        .to raise_error(Enliterator::ConfigurationError, /requires a topology/)
    end

    it "returns :whole when the topology declares wholes" do
      Enliterator.configure do |c|
        c.topology = book_topology
        c.default_reading_scope = :whole
      end
      expect(Enliterator.reading_scope).to eq(:whole)
    end
  end
end
