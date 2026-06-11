# frozen_string_literal: true

require "rails_helper"

# v0.24 — the catalog surface: the browse landing, search by meaning, the
# subject filter, type/page narrowing, and the context switcher scoping it
# like every surface. Degraded search renders honestly, never fakes.
RSpec.describe "Enliterator catalog", type: :request do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def enliterate!(title, body: "b", **claims)
    w = Widget.create!(title: title, body: body)
    claims.each do |key, value|
      visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded",
                                           applied: true, tier: "cheap")
      w.enliterator_claims.create!(key: key.to_s, value: value, status: "draft",
                                   confidence: 0.8, visit: visit)
    end
    w.enliterator_embeddings.create!(
      kind: "primary", embedding: embedder.embed(w.enliterator_text),
      dimensions: embedder.dimensions, model: "null"
    )
    w
  end

  it "renders the landing: stats, subject headings, recently tended, the grid, and the nav link" do
    w = enliterate!("Continuity of Operations",
                    summary: "How county clerks keep elections running.",
                    advisor: "Dr. Mara Voss")
    enliterate!("Second Doc", advisor: "Dr. Mara Voss")

    get "/enliterator/catalog"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(">Catalog</a>")                       # the nav item
      .and include("records enliterated")
      .and include("Subject headings")
      .and include("Dr. Mara Voss")
      .and include("Recently tended")
      .and include("Continuity of Operations")
      .and include("How county clerks keep elections running.")
      .and include("/enliterator/status/Widget/#{w.id}")                   # cards link to the full entry
  end

  it "renders honestly when nothing is enliterated" do
    get "/enliterator/catalog"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Nothing is enliterated yet")
  end

  it "searches by meaning and shows distances" do
    enliterate!("Alpha", body: "human trafficking and disaster response")
    enliterate!("Beta",  body: "wildfire fuel management")

    get "/enliterator/catalog", params: { q: "human trafficking" }
    expect(response.body).to include("Nearest records").and include("Alpha")
    expect(response.body).to match(/cosine distance/)
  end

  it "degrades honestly when the embedder is dead: names it, shows the browse, fakes nothing" do
    enliterate!("Alpha")
    dead = Class.new { def embed(_q) = nil }.new
    original = Enliterator.configuration.embedder_adapter
    Enliterator.configure { |c| c.embedder_adapter = dead }

    get "/enliterator/catalog", params: { q: "anything" }
    expect(response.body).to include("search unavailable")
      .and include("no results were faked")
      .and include("Alpha")                       # the browse still shows the holdings
    expect(response.body).not_to include("Nearest records")
  ensure
    Enliterator.configure { |c| c.embedder_adapter = original }
  end

  it "filters by subject heading, with results linking to the record entries" do
    a = enliterate!("A", advisor: "Dr. Voss")
    enliterate!("B", advisor: "Dr. Other")

    get "/enliterator/catalog", params: { key: "advisor", value: "Dr. Voss" }
    expect(response.body).to include("<code>advisor</code>")
      .and include("/enliterator/status/Widget/#{a.id}")
    expect(response.body).to include(">A</a>")
    expect(response.body).not_to include(">B</a>")
  end

  it "narrows by type, and an unknown type renders an honest note instead of a 500" do
    enliterate!("Typed", advisor: "Dr. Voss")

    get "/enliterator/catalog", params: { type: "Widget" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Widget only")

    get "/enliterator/catalog", params: { type: "Nonsense" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("unknown type “Nonsense”")
  end

  it "pages the grid, clamping absurd pages instead of rendering a blank" do
    stub_const("Enliterator::Catalog::PER_PAGE", 2)
    %w[First Second Third].each { |t| enliterate!(t) }

    get "/enliterator/catalog", params: { page: 2 }
    expect(response.body).to include(">First</a>").and include("page 2 of 2")

    get "/enliterator/catalog", params: { page: 999 }
    expect(response.body).to include("page 2 of 2")
  end

  it "scopes through the context switcher: non-members vanish from grid and headings" do
    ctx    = Enliterator::Context.create!(key: "election-security", name: "Election Security")
    member = enliterate!("Member Doc", advisor: "Dr. Voss")
    member.place_in_context!(ctx)
    enliterate!("Outsider Doc", advisor: "Dr. Voss")

    get "/enliterator/catalog", params: { context: "election-security" }
    expect(response.body).to include("Member Doc")
    expect(response.body).not_to include("Outsider Doc")
    expect(response.body).to include("Dr. Voss <strong>1</strong>")   # the heading count, scoped

    get "/enliterator/catalog", params: { context: "root" }
    expect(response.body).to include("Member Doc").and include("Outsider Doc")
  end

  it "wanders to a random record, or back to the catalog with an honest note when empty" do
    get "/enliterator/catalog/wander"
    expect(response).to redirect_to("/enliterator/catalog")

    w = enliterate!("Only One")
    get "/enliterator/catalog/wander"
    expect(response).to redirect_to("/enliterator/status/Widget/#{w.id}")
  end
end
