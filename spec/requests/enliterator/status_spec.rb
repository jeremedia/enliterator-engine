# frozen_string_literal: true

require "rails_helper"

# v0.6 status browser. Mounted at /enliterator in the dummy host.
RSpec.describe "Enliterator status browser", type: :request do
  let(:widget) { Widget.create!(title: "Acme", body: "a body worth tending") }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap", "quality" ]
      end
    end
    widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, model: "cheap", tier: "cheap")
    widget.enliterator_claims.create!(key: "summary", value: "An account of Acme.", status: "draft")
  end

  it "GET /enliterator/ (root) renders the status overview" do
    get "/enliterator/"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Status").and include("summary")
  end

  it "GET /enliterator/status renders facet cards + the health table" do
    get "/enliterator/status"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Facets").and include("Tending health")
  end

  it "highlights a null adapter in the health table (the smoke alarm)" do
    widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, model: "null", tier: "cheap")
    get "/enliterator/status"
    expect(response.body).to include("null adapter ran")
  end

  it "GET /enliterator/status/Widget/:id renders the record's claims + visits" do
    get "/enliterator/status/Widget/#{widget.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("An account of Acme.").and include("Live claims")
  end

  it "404s an unknown record id" do
    get "/enliterator/status/Widget/0"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("No tended record")
  end

  it "404s (allow-list) a class that isn't a registered tendable model" do
    get "/enliterator/status/String/1"
    expect(response).to have_http_status(:not_found)
  end
end
