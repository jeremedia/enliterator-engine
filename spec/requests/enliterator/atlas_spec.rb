# frozen_string_literal: true

require "rails_helper"

# v0.21 — the Atlas surface: live mode fetches its data asynchronously, the
# standalone export embeds it, /atlas/data serves JSON, and the nav's context
# switcher scopes it like every surface.
RSpec.describe "Enliterator atlas", type: :request do
  def tended_claim!(record, key:, value:)
    visit = record.enliterator_visits.create!(facet: "summary", status: "succeeded",
                                              applied: true, tier: "cheap")
    record.enliterator_claims.create!(key: key, value: value, status: "draft",
                                      confidence: 0.8, visit: visit)
  end

  it "renders the live page as a fast shell with a data URL and the nav link present" do
    w = Widget.create!(title: "Continuity of Operations", body: "b")
    tended_claim!(w, key: "advisor", value: "Dr. Mara Voss")

    get "/enliterator/atlas"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("window.ATLAS_DATA = null")
      .and include("window.ATLAS_DATA_URL = \"/enliterator/atlas/data?mode=overview\"")
      .and include(">Atlas</a>")           # the nav item
      .and include("fetch(dataUrl")
      .and include("Enliterator Atlas renderer vendor bundle")
    expect(response.body).not_to include("window.ATLAS_EMBEDDED = true")
    expect(response.body).not_to include("Continuity of Operations")
  end

  it "serves honest empty data when nothing is tended" do
    get "/enliterator/atlas/data"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('"nodes":[]')
  end

  it "serves the JSON at /atlas/data" do
    w = Widget.create!(title: "A Record", body: "b")
    tended_claim!(w, key: "advisor", value: "Dr. Json")

    get "/enliterator/atlas/data"
    json = JSON.parse(response.body)
    expect(json["meta"]["records"]).to eq(1)
    expect(json["meta"]["mode"]).to eq("explore")
    expect(json["nodes"].map { |n| n["label"] }).to include("A Record", "Dr. Json")
  end

  it "serves overview JSON when requested by the live shell" do
    w = Widget.create!(title: "Overview Record", body: "b")
    tended_claim!(w, key: "advisor", value: "Dr. Overview")

    get "/enliterator/atlas/data", params: { mode: "overview" }
    json = JSON.parse(response.body)
    expect(json["meta"]["mode"]).to eq("overview")
    expect(json["nodes"].size).to be <= 350
    expect(json["edges"].all? { |edge| edge.key?("category") }).to be(true)
  end

  it "renders the standalone export: one self-contained file, embedded data, no click-through" do
    w = Widget.create!(title: "Exported Doc", body: "b")
    tended_claim!(w, key: "advisor", value: "Dr. Export")

    html = Enliterator::AtlasController.render(
      template: "enliterator/atlas/export", layout: false,
      assigns: { atlas: Enliterator::Atlas.assemble, title: "Spec Collection" }
    )
    expect(html).to include("<!DOCTYPE html>")
      .and include("Atlas — Spec Collection")
      .and include("window.ATLAS_DATA")
      .and include("window.ATLAS_EMBEDDED = true")
      .and include("Exported Doc")
      .and include("Prepared ")
      .and include("Enliterator Atlas renderer vendor bundle")
    expect(html).not_to include("stylesheet_link_tag")   # self-contained, no asset pipeline
    expect(html).not_to include("javascript_include_tag")
    expect(html).not_to include("https://cdn")
  end

  it "scopes through the context switcher like every surface" do
    ctx   = Enliterator::Context.create!(key: "election-security", name: "Election Security")
    other = Enliterator::Context.create!(key: "elsewhere", name: "Elsewhere")
    inside  = Widget.create!(title: "Inside Doc", body: "b")
    outside = Widget.create!(title: "Outside Doc", body: "b")
    v1 = inside.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, context: ctx)
    inside.enliterator_claims.create!(key: "advisor", value: "Dr. In", status: "draft", visit: v1, context: ctx)
    v2 = outside.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, context: other)
    outside.enliterator_claims.create!(key: "advisor", value: "Dr. Out", status: "draft", visit: v2, context: other)

    get "/enliterator/atlas", params: { context: "election-security" }
    expect(response.body).to include("/enliterator/atlas/data")
    expect(response.body).to include("mode=overview")
    expect(response.body).to include("context=election-security")

    get "/enliterator/atlas/data", params: { context: "election-security" }
    expect(response.body).to include("Inside Doc")
    expect(response.body).not_to include("Outside Doc")
  end

  describe "GET /enliterator/atlas/node" do
    it "returns claims + lacunae JSON for a record node" do
      w = Widget.create!(title: "Inspected", body: "x")
      v = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
      w.enliterator_claims.create!(key: "summary", value: "S", status: "draft", confidence: 0.8,
                                   attributed_to: "cheap:x", tier: "cheap", visit: v, context_id: nil)
      get "/enliterator/atlas/node", params: { type: "Widget", id: w.id }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["node"]["label"]).to eq("Inspected")
      expect(body["claims"].first["key"]).to eq("summary")
    end
  end
end
