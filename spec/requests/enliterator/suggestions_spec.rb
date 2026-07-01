# frozen_string_literal: true

require "rails_helper"

# v0.7 suggestion review — the governed-vocabulary queue, mounted at /enliterator.
RSpec.describe "Enliterator suggestion review", type: :request do
  let(:w) { Widget.create!(title: "A", body: "x") }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract.", authored_by: "The author(s)." }
        ladder [ "cheap" ]
      end
    end
    Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "keywords", rationale: "kw terms", status: "pending")
    Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "author",   rationale: "a name",  status: "pending")
  end

  it "GET /enliterator/suggestions renders the ranked queue" do
    get "/enliterator/suggestions"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Authority control").and include("keywords").and include("author")
  end

  it "approve marks the key approved and surfaces it under contract additions" do
    post "/enliterator/suggestions/verdict", params: { proposed_key: "keywords", decision: "approve" }
    expect(response).to redirect_to("/enliterator/suggestions")
    expect(Enliterator::Suggestion.where(proposed_key: "keywords", status: "approved").count).to eq(1)
    follow_redirect!
    expect(response.body).to include("codify in your policy").and include("keywords")
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

  describe "the considerer (v0.8 — v0.48: now async)" do
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

    it "POST consider opens a run, applies verdicts (via inline execute! stub), redirects with async notice" do
      # Run execute! inline so we can verify the consider results synchronously in the test.
      allow_any_instance_of(Enliterator::ConsidererRun).to receive(:execute_async!) do |run|
        run.execute!
        Thread.new {}
      end

      post "/enliterator/suggestions/consider"
      expect(response).to redirect_to("/enliterator/suggestions")

      # The considerer work ran synchronously via the stub — verify its effect.
      expect(Enliterator::Suggestion.find_by(proposed_key: "author").status).to eq("mapped")
      expect(Enliterator::ProposedTerm.find_by(proposed_key: "keywords").recommended_decision).to eq("approve")

      follow_redirect!
      # v0.48: the notice says "Considering… (run #N)" — the keyword is still in the pending list
      # (the async run hasn't reloaded the page yet) so it still appears in the page body.
      expect(response.body).to include("Considering").and include("keywords")
    end
  end

  it "ranks the pending queue by pressure" do
    # bump author's pressure with a second proposal
    Enliterator::Suggestion.create!(tendable: Widget.create!(title: "B", body: "y"), facet: "summary", proposed_key: "author", rationale: "again", status: "pending")
    get "/enliterator/suggestions"
    expect(response.body.index("author")).to be < response.body.index("keywords")
  end

  describe "v0.53 — reviewer-flow-first cards (recommendation-led, pre-filled, type-ahead)" do
    def proposed_with_rec(key, decision: "map", map_to: nil, confidence: 0.95)
      Enliterator::ProposedTerm.create!(
        proposed_key: key, recommended_decision: decision,
        recommended_map_to: map_to, recommended_confidence: confidence, recommended_rationale: "rec"
      )
    end
    # the Map target is a type-ahead input over a shared datalist; a pre-filled input carries
    # name="mapped_to" ... value="<term>". (value="<term>" also appears on datalist <option>s,
    # so we match against the INPUT specifically.)
    def prefilled?(body, term) = body.match?(/name="mapped_to"[^>]*value="#{Regexp.escape(term)}"/)

    it "always pre-fills a canonical map target — above the floor" do
      proposed_with_rec("author", map_to: "authored_by", confidence: 0.95)
      get "/enliterator/suggestions"
      expect(prefilled?(response.body, "authored_by")).to be(true)
      expect(response.body).to include("rec-map")   # the Map action leads
    end

    it "ALSO pre-fills below the floor, but flags it low-confidence (v0.50 gate removed)" do
      proposed_with_rec("author", map_to: "authored_by", confidence: 0.50)
      get "/enliterator/suggestions"
      expect(prefilled?(response.body, "authored_by")).to be(true)   # now pre-filled
      expect(response.body).to include("· 50%").and include("low confidence")  # but marked
    end

    it "renders a shared type-ahead datalist of the preferred vocabulary" do
      proposed_with_rec("author", map_to: "authored_by")
      get "/enliterator/suggestions"
      expect(response.body).to include('<datalist id="canonical-terms"')
      expect(response.body).to include('<option value="authored_by">')
    end

    it "leads with Approve when the recommendation is approve" do
      proposed_with_rec("author", decision: "approve")
      get "/enliterator/suggestions"
      expect(response.body).to include("rec-approve")
    end

    it "shows a pending-sibling hint (and no pre-fill) when the target isn't yet canonical" do
      proposed_with_rec("author", map_to: "topics", confidence: 0.95)   # topics: not a preferred term
      get "/enliterator/suggestions"
      expect(response.body).to include("still pending").and include("approve it first")
      expect(prefilled?(response.body, "topics")).to be(false)
    end

    it "map onto a non-canonical target alerts and changes nothing (free-text guard)" do
      post "/enliterator/suggestions/verdict", params: { proposed_key: "author", decision: "map", mapped_to: "not_a_term" }
      expect(flash[:alert]).to be_present
      expect(Enliterator::Suggestion.find_by(proposed_key: "author").status).to eq("pending")
    end

    it "reveals FULL per-record evidence in an expander — no truncation dead-end (v0.54)" do
      long = "The chapter grounds its whole argument in thermodynamic dispersal structure. " * 6  # > 240 chars
      Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "author",
                                      rationale: long, example_value: "a full, specific example claim value", status: "pending")
      proposed_with_rec("author", decision: "approve")
      get "/enliterator/suggestions"
      expect(response.body).to include("Evidence —")
      expect(response.body).to include(long.strip)                              # full rationale, untruncated
      expect(response.body).to include("a full, specific example claim value")  # the example too
    end

    it "reveals the map target's definition and what already folds onto it (v0.54)" do
      Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "byline",
                                      rationale: "r", status: "mapped", mapped_to: "authored_by")  # existing variant
      proposed_with_rec("author", decision: "map", map_to: "authored_by", confidence: 0.9)
      get "/enliterator/suggestions"
      expect(response.body).to include("Map target").and include("authored_by")
      expect(response.body).to include("byline")             # the existing variant is shown
      expect(response.body).to include("The author(s).")     # authored_by's definition (from staffing)
    end

    it "a 0-row verdict alerts instead of a green success notice (rule 3)" do
      post "/enliterator/suggestions/verdict", params: { proposed_key: "ghost-key", decision: "approve" }
      expect(response).to redirect_to("/enliterator/suggestions")
      expect(flash[:alert]).to be_present
      expect(flash[:notice]).to be_blank
    end
  end

  describe "convergence surfaces (v0.9)" do
    it "renders the 'Re-proposed after a verdict' panel for keys the model keeps re-asking" do
      Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "thematic_focus", rationale: "r", status: "mapped", mapped_to: "summary")
      Enliterator::ProposedTerm.create!(proposed_key: "thematic_focus", post_verdict_attempts: 4)
      get "/enliterator/suggestions"
      expect(response.body).to include("Re-proposed after a verdict").and include("thematic_focus")
      expect(response.body).to match(/mapped\s*(→|&rarr;)/) # shows the verdict it's overruling
    end

    it "labels an approved key as already live, not merely advised" do
      post "/enliterator/suggestions/verdict", params: { proposed_key: "keywords", decision: "approve" }
      follow_redirect!
      expect(response.body).to include("Approved &amp; live").and include("already live")
    end
  end
end
