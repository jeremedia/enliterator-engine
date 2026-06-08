# frozen_string_literal: true

require "rails_helper"

# v0.7 suggestion review — the governed-vocabulary queue, mounted at /enliterator.
RSpec.describe "Enliterator suggestion review", type: :request do
  let(:w) { Widget.create!(title: "A", body: "x") }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        stream :summary, tier: "cheap", keys: { summary: "An abstract.", authored_by: "The author(s)." }
        ladder [ "cheap" ]
      end
    end
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "keywords", rationale: "kw terms", status: "pending")
    Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: "author",   rationale: "a name",  status: "pending")
  end

  it "GET /enliterator/suggestions renders the ranked queue" do
    get "/enliterator/suggestions"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Vocabulary requests").and include("keywords").and include("author")
  end

  it "approve marks the key approved and surfaces it under contract additions" do
    post "/enliterator/suggestions/verdict", params: { proposed_key: "keywords", decision: "approve" }
    expect(response).to redirect_to("/enliterator/suggestions")
    expect(Enliterator::Suggestion.where(proposed_key: "keywords", status: "approved").count).to eq(1)
    follow_redirect!
    expect(response.body).to include("add to your contract").and include("keywords")
  end

  it "map records the canonical target" do
    post "/enliterator/suggestions/verdict", params: { proposed_key: "author", decision: "map", mapped_to: "authored_by" }
    s = Enliterator::Suggestion.find_by(proposed_key: "author")
    expect(s.status).to eq("mapped")
    expect(s.mapped_to).to eq("authored_by")
  end

  it "map without a target redirects with an alert and leaves it pending" do
    post "/enliterator/suggestions/verdict", params: { proposed_key: "author", decision: "map" }
    expect(response).to redirect_to("/enliterator/suggestions")
    expect(Enliterator::Suggestion.find_by(proposed_key: "author").status).to eq("pending")
  end

  it "reject drops it from pending" do
    expect {
      post "/enliterator/suggestions/verdict", params: { proposed_key: "keywords", decision: "reject" }
    }.to change { Enliterator::Suggestion.pending.count }.by(-1)
  end

  it "an unknown decision redirects with an alert and changes nothing" do
    post "/enliterator/suggestions/verdict", params: { proposed_key: "keywords", decision: "bogus" }
    expect(response).to redirect_to("/enliterator/suggestions")
    expect(Enliterator::Suggestion.pending.count).to eq(2)
  end

  describe "the considerer (v0.8)" do
    # Resolves via configuration.llm_adapter (gateway unconfigured in tests).
    class ReqSlateStub
      def model_id = "stub"
      def decide(messages:, schema:, tool_name:, tags: [])
        { "recommendations" => [
          { "proposed_key" => "author",   "decision" => "map",     "map_to" => "authored_by", "rationale" => "synonym",     "confidence" => 0.95 },
          { "proposed_key" => "keywords", "decision" => "approve", "rationale" => "new concept", "confidence" => 0.9 }
        ] }
      end
    end
    before { Enliterator.configure { |c| c.llm_adapter = ReqSlateStub.new } }

    it "POST consider auto-applies the map and holds the approve for ratification" do
      post "/enliterator/suggestions/consider"
      expect(response).to redirect_to("/enliterator/suggestions")
      expect(Enliterator::Suggestion.find_by(proposed_key: "author").status).to eq("mapped")
      expect(Enliterator::ProposedTerm.find_by(proposed_key: "keywords").recommended_decision).to eq("approve")
      follow_redirect!
      expect(response.body).to include("Considered").and include("keywords")
    end
  end

  it "ranks the pending queue by pressure" do
    # bump author's pressure with a second proposal
    Enliterator::Suggestion.create!(tendable: Widget.create!(title: "B", body: "y"), stream: "summary", proposed_key: "author", rationale: "again", status: "pending")
    get "/enliterator/suggestions"
    expect(response.body.index("author")).to be < response.body.index("keywords")
  end
end
