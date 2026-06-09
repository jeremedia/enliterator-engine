# frozen_string_literal: true

require "rails_helper"

# v0.11 — the Settings surface: a read-only window onto this enliteration's org chart
# and accumulating vocabulary, mounted at /enliterator/settings.
RSpec.describe "Enliterator settings", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        stream :summary,      tier: "cheap",   keys: { summary: "An abstract." }
        stream :significance, tier: "quality", keys: { contribution: "What it adds." }, required: [ :contribution ]
        ladder [ "cheap", "quality" ]
        verify_floor "quality"
      end
    end
  end

  it "renders the org chart: streams, tiers, ladder, verify floor" do
    get "/enliterator/settings"
    expect(response).to have_http_status(:ok)
    expect(response.body)
      .to include("Settings")
      .and include("summary").and include("significance")
      .and include("cheap").and include("quality")
      .and include("cheap → quality")          # the escalation climb
  end

  it "shows the considerer + null-LLM-guard configuration" do
    get "/enliterator/settings"
    expect(response.body).to include("auto_safe").and include("Null-LLM guard")
  end

  it "marks an approved key as live in the effective contract" do
    w = Widget.create!(title: "T", body: "b")
    Enliterator::Suggestion.create!(tendable: w, stream: "significance", proposed_key: "keywords",
                                    rationale: "r", status: "approved")
    get "/enliterator/settings"
    expect(response.body).to include("keywords").and include("live")
  end

  it "links the vocabulary governance back to Requests" do
    get "/enliterator/settings"
    expect(response.body).to include("/enliterator/suggestions")
  end
end
