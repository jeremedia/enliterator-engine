# frozen_string_literal: true

require "rails_helper"

# v0.13 — the context switcher + the Contexts tree surface, mounted at /enliterator.
RSpec.describe "Enliterator contexts", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        context "executive-orders" do
          facet :directive, tier: "cheap", terms: { eo_number: "The EO number." }
        end
        ladder [ "cheap" ]
      end
    end
  end

  describe "with no tree seeded (flat install)" do
    it "Contexts explains how to seed; the nav has NO switcher; Status is unchanged" do
      get "/enliterator/contexts"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No contexts seeded yet")
      expect(response.body).not_to include("ctx-switch")

      get "/enliterator/"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "with a seeded tree" do
    let!(:root) { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
    let!(:eo)   { Enliterator::Context.create!(key: "executive-orders", name: "Executive Orders", parent: root) }
    let(:w)     { Widget.create!(title: "EO 14067", body: "x") }

    it "renders the tree with own facets, membership and scoped counts" do
      w.place_in_context!(eo)
      w.enliterator_claims.create!(key: "eo_number", value: "14067", status: "draft", context: eo)
      w.enliterator_claims.create!(key: "summary", value: "root claim", status: "draft") # NULL = root

      get "/enliterator/contexts"
      expect(response.body).to include("Executive Orders").and include("directive")
      expect(response.body).to include("whole collection")
    end

    it "the nav switcher selects a context via ?context= and persists it in a cookie" do
      get "/enliterator/", params: { context: "executive-orders" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Executive Orders")          # breadcrumb
      expect(response.body).to include(%(<option value="executive-orders" selected))

      get "/enliterator/"                                            # cookie persists
      expect(response.body).to include(%(<option value="executive-orders" selected))

      get "/enliterator/", params: { context: "root" }               # explicit reset
      expect(response.body).to include(%(<option value="root" selected))
    end

    it "an unknown context falls back to root instead of 500ing" do
      get "/enliterator/", params: { context: "nope" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(<option value="root" selected))
    end

    it "Status viewed through a context shows the context's EFFECTIVE facets" do
      get "/enliterator/", params: { context: "executive-orders" }
      expect(response.body).to include("directive")                  # own facet
      expect(response.body).to include("summary")                    # inherited root facet
    end

    it "Settings viewed through a context shows the merged policy with origin chips" do
      get "/enliterator/settings", params: { context: "executive-orders" }
      expect(response.body).to include("directive").and include("executive-orders")
      expect(response.body).to include("summary")                    # inherited
    end
  end
end
