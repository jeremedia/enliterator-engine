# frozen_string_literal: true

require "rails_helper"

# v0.52 — curator corrections on the standing vocabulary, exercised through the /vocabulary surface
# (re-route / promote / demote / merge / split), NOT raw SQL.
RSpec.describe "Enliterator authority corrections", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary,  tier: "cheap", terms: { summary: "s", authored_by: "a" }
        facet :coverage, tier: "cheap", terms: { concepts: "c" }
        ladder [ "cheap" ]
      end
    end
  end

  let(:w) { Widget.create!(title: "A", body: "x") }

  def sugg(key, status:, facet: "coverage", to: nil, on: nil)
    Enliterator::Suggestion.create!(tendable: on || w, facet: facet, proposed_key: key,
                                    rationale: "r", status: status, mapped_to: to)
  end

  describe "reroute (pure metadata)" do
    it "re-points a mapped variant onto a different preferred term" do
      sugg("case_studies", status: "approved")
      sugg("worked_ex", status: "mapped", to: "summary")
      post "/enliterator/vocabulary/reroute", params: { proposed_key: "worked_ex", to: "case_studies" }
      expect(response).to redirect_to("/enliterator/vocabulary")
      expect(Enliterator::Suggestion.find_by(proposed_key: "worked_ex").mapped_to).to eq("case_studies")
    end

    it "rejects a non-canonical target with an alert, changing nothing" do
      sugg("worked_ex", status: "mapped", to: "summary")
      post "/enliterator/vocabulary/reroute", params: { proposed_key: "worked_ex", to: "not_a_term" }
      expect(flash[:alert]).to be_present
      expect(Enliterator::Suggestion.find_by(proposed_key: "worked_ex").mapped_to).to eq("summary")
    end
  end

  describe "promote (joins Vocabulary.for)" do
    it "promotes a mapped variant to a preferred term" do
      sugg("case_studies", status: "mapped", to: "summary")
      expect(Enliterator::Vocabulary.for(:coverage)&.key?("case_studies")).to be_falsey
      post "/enliterator/vocabulary/promote", params: { proposed_key: "case_studies" }
      s = Enliterator::Suggestion.find_by(proposed_key: "case_studies")
      expect(s.status).to eq("approved")
      expect(s.mapped_to).to be_nil
      expect(Enliterator::Vocabulary.for(:coverage)&.key?("case_studies")).to be(true)
    end
  end

  describe "demote (leaves Vocabulary.for)" do
    it "demotes a preferred term to rejected" do
      sugg("case_studies", status: "approved")
      expect(Enliterator::Vocabulary.for(:coverage)&.key?("case_studies")).to be(true)
      post "/enliterator/vocabulary/demote", params: { proposed_key: "case_studies", to_status: "rejected" }
      expect(Enliterator::Suggestion.find_by(proposed_key: "case_studies").status).to eq("rejected")
      expect(Enliterator::Vocabulary.for(:coverage)&.key?("case_studies")).to be_falsey
    end

    it "demote-to-mapped requires a legal target (no dangling USE-reference)" do
      sugg("case_studies", status: "approved")
      post "/enliterator/vocabulary/demote", params: { proposed_key: "case_studies", to_status: "mapped" }
      expect(flash[:alert]).to be_present
      expect(Enliterator::Suggestion.find_by(proposed_key: "case_studies").status).to eq("approved")
    end

    it "demote-to-mapped onto a legal target folds it" do
      sugg("case_studies", status: "approved")
      post "/enliterator/vocabulary/demote", params: { proposed_key: "case_studies", to_status: "mapped", to: "summary" }
      s = Enliterator::Suggestion.find_by(proposed_key: "case_studies")
      expect(s.status).to eq("mapped")
      expect(s.mapped_to).to eq("summary")
    end

    it "rejects a bogus to_status with an alert, changing nothing" do
      sugg("case_studies", status: "approved")
      post "/enliterator/vocabulary/demote", params: { proposed_key: "case_studies", to_status: "bogus" }
      expect(flash[:alert]).to be_present
      expect(Enliterator::Suggestion.find_by(proposed_key: "case_studies").status).to eq("approved")
    end
  end

  describe "merge (folds a whole ring, never resurrects rejected)" do
    it "re-points variants and folds the head, leaving rejected rows rejected" do
      sugg("case_studies", status: "approved")                       # the ring head (from)
      sugg("hist", status: "mapped", to: "case_studies")             # a variant folded onto from
      # a deliberately-rejected proposal of `from` (in another record) — must NOT resurrect:
      sugg("case_studies", status: "rejected", on: Widget.create!(title: "B", body: "y"))

      post "/enliterator/vocabulary/merge", params: { from: "case_studies", into: "summary" }
      expect(response).to redirect_to("/enliterator/vocabulary")
      expect(Enliterator::Suggestion.find_by(proposed_key: "hist").mapped_to).to eq("summary")           # variant re-pointed
      expect(Enliterator::Suggestion.where(proposed_key: "case_studies", status: "mapped", mapped_to: "summary").count).to eq(1)  # head folded
      expect(Enliterator::Suggestion.where(proposed_key: "case_studies", status: "rejected").count).to eq(1)  # killed row untouched
    end

    it "refuses merging a term into itself" do
      sugg("case_studies", status: "approved")
      post "/enliterator/vocabulary/merge", params: { from: "case_studies", into: "case_studies" }
      expect(flash[:alert]).to be_present
    end
  end

  describe "settle! — stale governance signals, cross-context guarded" do
    it "clears the held recommendation and zeroes post_verdict_attempts when nothing is pending" do
      sugg("case_studies", status: "mapped", to: "summary")
      Enliterator::ProposedTerm.create!(proposed_key: "case_studies", post_verdict_attempts: 3,
                                        recommended_decision: "map", recommended_map_to: "summary",
                                        recommended_confidence: 0.5)
      post "/enliterator/vocabulary/promote", params: { proposed_key: "case_studies" }
      pt = Enliterator::ProposedTerm.find_by(proposed_key: "case_studies")
      expect(pt.post_verdict_attempts).to eq(0)
      expect(pt.recommended_decision).to be_nil
    end

    it "does NOT clear when the key still has pending rows somewhere" do
      sugg("case_studies", status: "mapped", to: "authored_by")
      sugg("case_studies", status: "pending")     # a still-live disagreement
      Enliterator::ProposedTerm.create!(proposed_key: "case_studies", post_verdict_attempts: 3)
      post "/enliterator/vocabulary/reroute", params: { proposed_key: "case_studies", to: "summary" }
      expect(Enliterator::ProposedTerm.find_by(proposed_key: "case_studies").post_verdict_attempts).to eq(3)
    end
  end

  it "a 0-row correction alerts instead of a green success notice (rule 3)" do
    post "/enliterator/vocabulary/promote", params: { proposed_key: "ghost" }
    expect(response).to redirect_to("/enliterator/vocabulary")
    expect(flash[:alert]).to be_present
    expect(flash[:notice]).to be_blank
  end
end
