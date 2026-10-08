# frozen_string_literal: true

require "rails_helper"

# v0.89 — only one deployment curates. `config.curation_writes = false` marks
# an import target: review verdicts, vocabulary decisions, suggestion
# verdicts and the MCP curation tools refuse (their writes would be replaced
# by the next import), and the UI says so. Unset: byte-identical.
RSpec.describe "v0.89 curation writes", type: :request do
  around do |ex|
    prior = [ Enliterator.configuration.curation_writes, Enliterator.configuration.curation_home ]
    ex.run
    Enliterator.configuration.curation_writes, Enliterator.configuration.curation_home = prior
  end

  let(:claim) do
    w = Widget.create!(title: "T", body: "b")
    visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    w.enliterator_claims.create!(key: "finding", value: "x", status: "draft", confidence: 0.8, visit: visit)
  end
  let!(:audit) { Enliterator::Audit.create!(claim: claim, verdict: "unsupported", source: "examiner", auditor: "q:m") }

  def refuse!
    Enliterator.configuration.curation_writes = false
    Enliterator.configuration.curation_home = "dev.example.org/enliterator"
  end

  it "default: a review verdict is written" do
    post "/enliterator/review/verdict", params: { audit_id: audit.id, decision: "confirm" }
    expect(Enliterator::Audit.human.count).to eq(1)
  end

  it "read-only: the review verdict is refused, nothing written, and the refusal names where to curate" do
    refuse!
    post "/enliterator/review/verdict", params: { audit_id: audit.id, decision: "confirm" },
                                        headers: { "HTTP_REFERER" => "/enliterator/review" }
    expect(Enliterator::Audit.human.count).to eq(0)
    expect(response).to redirect_to("/enliterator/review")
    expect(flash[:alert]).to include("read-only", "dev.example.org/enliterator")
  end

  it "read-only: suggestion verdicts and the considerer trigger are refused" do
    refuse!
    post "/enliterator/suggestions/consider"
    expect(flash[:alert]).to include("read-only")
    post "/enliterator/suggestions/verdict", params: { proposed_key: "x", decision: "reject" }
    expect(flash[:alert]).to include("read-only")
  end

  it "read-only: the MCP curation tools refuse; read tools are unaffected" do
    refuse!
    expect { Enliterator::Mcp.dispatch("flag_claim", "claim_id" => claim.id, "verdict" => "unsupported", "note" => "n") }
      .to raise_error(Enliterator::Mcp::CurationWritesDisabled, /flag_claim: Curation is read-only/)
    expect { Enliterator::Mcp.dispatch("record_entry", "type" => "Widget", "id" => claim.tendable_id.to_s) }
      .not_to raise_error
  end

  it "read-only: the review page shows the banner and hides the verdict forms" do
    refuse!
    get "/enliterator/review"
    expect(response.body).to include("Curation is read-only here")
    expect(response.body).to include(%(form[action*="/review/verdict"]))
  end

  it "default: no banner, no hiding style" do
    get "/enliterator/review"
    expect(response.body).not_to include("Curation is read-only here")
  end
end
