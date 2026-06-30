# frozen_string_literal: true

require "rails_helper"

# v0.51 — the authority file surface, mounted at /enliterator/vocabulary.
RSpec.describe "Enliterator authority file", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "s", authored_by: "a" }
        ladder [ "cheap" ]
      end
    end
  end

  it "renders the zero-state when nothing has been proposed (adoption-gated, render-on-data)" do
    get "/enliterator/vocabulary"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("No vocabulary yet")
    # the data frame is ABSENT when unadopted — no metrics strip, no rings heading
    expect(response.body).not_to include("preferred terms")
    expect(response.body).not_to include("by sprawl")
  end

  it "renders rings + the metrics strip once proposals are resolved" do
    w = Widget.create!(title: "A", body: "x")
    Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "case_studies",
                                    rationale: "r", status: "approved")
    Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "worked_examples",
                                    rationale: "r", status: "mapped", mapped_to: "case_studies")

    get "/enliterator/vocabulary"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("case_studies").and include("worked_examples")
    expect(response.body).to include("preferred terms")   # the metrics strip rendered
    expect(response.body).to include("by sprawl")          # the rings heading rendered
  end
end
