# frozen_string_literal: true

require "rails_helper"

# v0.10 — the About explainer, mounted at /enliterator/about. Prose renders with no
# data; the live stats strip appears only once the collection has succeeded visits.
RSpec.describe "Enliterator about page", type: :request do
  it "renders the explainer with no data (prose, no live strip)" do
    get "/enliterator/about"
    expect(response).to have_http_status(:ok)
    expect(response.body)
      .to include("What is Enliterator?")
      .and include("Enliteracy")
      .and include("attention that compounds")
    expect(response.body).not_to include("This collection, right now") # no visits yet
  end

  it "links the other three surfaces" do
    get "/enliterator/about"
    expect(response.body).to include("/enliterator").and include("/enliterator/chat").and include("/enliterator/suggestions")
  end

  it "shows the live stats strip once the collection has been tended" do
    w = Widget.create!(title: "T", body: "b")
    Enliterator::Visit.create!(tendable: w, facet: "summary", tier: "cheap",
                               status: "succeeded", applied: true, confidence: 1.0, escalation_step: 0)
    Enliterator::Claim.create!(tendable: w, key: "summary", value: "x", status: "draft")

    get "/enliterator/about"
    expect(response.body).to include("This collection, right now").and include("records tended")
  end
end
