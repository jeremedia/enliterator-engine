# frozen_string_literal: true

require "rails_helper"

# v0.13 — per-context facet declarations in the staffing Policy. Facets declared
# inside a `context "key" do` block belong to that collection context; a context
# inherits its ancestors' facets (resolution walks the path root → self,
# descendant wins). Declarations OUTSIDE any block are the root's — so a
# contextless policy is byte-identical to v0.12. (The Policy's `context` block is
# the COLLECTION context — unrelated to `context_cap`, the LLM window cap.)
RSpec.describe "Enliterator::Staffing::Policy context blocks (v0.13)" do
  let(:policy) do
    Enliterator::Staffing::Policy.new do
      # root declarations (outside any block)
      facet :description, tier: "cheap", terms: { summary: "An abstract." }
      assign :subjects, tier: "cheap"

      context "executive-orders" do
        facet :directive, tier: "quality", terms: { eo_number: "The EO number." },
              required: [ :eo_number ]
        # a child OVERRIDE of a root facet (descendant wins)
        facet :description, tier: "quality", terms: { summary: "A directive précis." }
      end

      context "crs-reports" do
        facet :policy_analysis, tier: "cheap", terms: { affected_agencies: "Agencies affected." }
      end

      ladder [ "cheap", "quality" ]
    end
  end

  let(:eo_path)  { %w[hsdl executive-orders] }
  let(:crs_path) { %w[hsdl crs-reports] }

  it "no-path lookups resolve to root only (v0.12 byte-identical)" do
    expect(policy.tier_for(:description)).to eq("cheap")
    expect(policy.terms_for(:description)).to eq("summary" => "An abstract.")
    expect(policy.terms_for(:directive)).to be_nil          # context facet invisible at root
    expect(policy.assignments.keys).to eq(%w[description subjects])
  end

  it "a context's own facet resolves along its path — and is invisible to siblings" do
    expect(policy.tier_for(:directive, path: eo_path)).to eq("quality")
    expect(policy.terms_for(:directive, path: eo_path)).to eq("eo_number" => "The EO number.")
    expect(policy.required_terms(:directive, path: eo_path)).to eq([ "eo_number" ])
    expect(policy.terms_for(:directive, path: crs_path)).to be_nil
  end

  it "a descendant's re-declaration of a root facet wins on its path only" do
    expect(policy.terms_for(:description, path: eo_path)).to eq("summary" => "A directive précis.")
    expect(policy.tier_for(:description, path: eo_path)).to eq("quality")
    expect(policy.terms_for(:description, path: crs_path)).to eq("summary" => "An abstract.")  # inherited root
  end

  it "facets_for merges root → path (deepest declaration attributed)" do
    expect(policy.facets_for(eo_path)).to eq(
      "description" => "executive-orders", "subjects" => "root", "directive" => "executive-orders"
    )
    expect(policy.facets_for).to eq("description" => "root", "subjects" => "root")
  end

  it "facets_declared_in returns ONLY a context's own facets (rule 2: tending scope)" do
    expect(policy.facets_declared_in("executive-orders")).to contain_exactly("directive", "description")
    expect(policy.facets_declared_in("root")).to eq(%w[description subjects])
    expect(policy.facets_declared_in("hsdl")).to eq([])     # tree key with no block: contributes nothing
  end

  it "referenced_tiers includes tiers named only inside context blocks" do
    expect(policy.referenced_tiers).to include("quality")
  end

  it "context blocks cannot nest" do
    expect {
      Enliterator::Staffing::Policy.new do
        context("a") { context("b") {} }
      end
    }.to raise_error(ArgumentError, /nest/)
  end
end
