# frozen_string_literal: true

require "rails_helper"

# v0.18 — the Review surface: the human anchor's queue and write path.
RSpec.describe "Enliterator review (quality review)", type: :request do
  let(:widget) { Widget.create!(title: "Acme", body: "the source text of record") }
  let(:visit) do
    widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
  end

  def claim!(key: "summary", value: "a take")
    widget.enliterator_claims.create!(key: key, value: value, status: "draft", tier: "cheap", visit: visit)
  end

  def examined!(claim, verdict: "contradicted", proposal: "the right value")
    Enliterator::Audit.create!(claim: claim, verdict: verdict, source: "examiner",
                               rationale: "the source disagrees", corrected_value: proposal,
                               source_digest: Digest::MD5.hexdigest(widget.enliterator_text(facet: "summary")))
  end

  it "renders the empty state before any examination" do
    get "/enliterator/review"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("no claims have been examined yet")
  end

  it "queues examined claims with the examiner's verdict, rationale, and proposal" do
    examined!(claim!)
    get "/enliterator/review"
    expect(response.body).to include("examiner: contradicted")
      .and include("the source disagrees")
      .and include("the right value")           # pre-filled into the correct form
      .and include("Confirm contradicted")
      .and include("Acme")                      # v0.62: the record's human label, not its uuid
  end

  it "shows the record's human label linked to its entry, uuid demoted to a title attr" do
    examined!(claim!)
    get "/enliterator/review"
    expect(response.body).to include(">Acme</a>")
      .and include("/enliterator/status/Widget/#{widget.id}")
      .and include(%(title="Widget/#{widget.id}"))
  end

  it "mixes examiner-supported claims into the queue (the false-supported detector)" do
    examined!(claim!(key: "a"), verdict: "supported")
    examined!(claim!(key: "b"), verdict: "contradicted")
    get "/enliterator/review"
    expect(response.body).to include("examiner: supported").and include("examiner: contradicted")
  end

  it "confirm records an agreeing human audit" do
    audit = examined!(claim!)
    post "/enliterator/review/verdict", params: { audit_id: audit.id, decision: "confirm" }
    expect(response).to redirect_to("/enliterator/review")
    human = Enliterator::Audit.human.last
    expect(human.verdict).to eq("contradicted")
    expect(human.claim_id).to eq(audit.claim_id)
  end

  it "overrule records the chosen verdict — never imputed" do
    audit = examined!(claim!)
    post "/enliterator/review/verdict", params: { audit_id: audit.id, decision: "overrule", verdict: "supported" }
    expect(Enliterator::Audit.human.last.verdict).to eq("supported")

    post "/enliterator/review/verdict", params: { audit_id: audit.id, decision: "overrule", verdict: "nonsense" }
    follow_redirect!
    expect(response.body).to include("Pick a verdict")
  end

  it "correct mints the locked human claim, links it on the audit, and the queue clears" do
    c = claim!
    audit = examined!(c)
    post "/enliterator/review/verdict",
         params: { audit_id: audit.id, decision: "correct", value: "the human truth", note: "amber" }

    fresh = widget.enliterator_claims.live.find_by(key: "summary")
    expect(fresh.value).to eq("the human truth")
    expect(fresh.locked).to be(true)
    expect(fresh.attributed_to).to eq("human:amber")
    expect(c.reload.superseded_by_id).to eq(fresh.id)
    human = Enliterator::Audit.human.last
    expect(human.corrected_claim_id).to eq(fresh.id)
    expect(human.verdict).to eq("contradicted")

    get "/enliterator/review"
    expect(response.body).not_to include("Confirm contradicted")   # reviewed — out of the queue
  end

  it "a claim re-tended after examination loses the Correct action but keeps confirm/overrule" do
    c = claim!
    audit = examined!(c)
    replacement = widget.enliterator_claims.create!(key: "summary", value: "newer", status: "draft", visit: visit)
    c.supersede!(replacement)

    get "/enliterator/review"
    expect(response.body).to include("re-tended after examination")
    expect(response.body).not_to include('value="correct"')

    # Racing POST anyway → loud refusal, chain intact.
    post "/enliterator/review/verdict", params: { audit_id: audit.id, decision: "correct", value: "x" }
    follow_redirect!
    expect(response.body).to include("re-tended after examination")
    expect(c.reload.superseded_by_id).to eq(replacement.id)
  end

  it "flags a source that changed since examination" do
    audit = examined!(claim!)
    audit.update!(source_digest: "stale-digest")
    get "/enliterator/review"
    expect(response.body).to include("source changed since examination")
  end

  describe "v0.62 — the focus view (one claim per screen, full source beside it)" do
    it "renders a focus template + hidden open affordance per queue item, and the shell" do
      audit = examined!(claim!)
      get "/enliterator/review"
      expect(response.body).to include("<template data-focus-item")
        .and include(%(data-focus-key="#{audit.id}"))
        .and include(%(data-focus-open="#{audit.id}"))
        .and include('<dialog class="focus-dialog"')
        .and include(%(data-source-url="/enliterator/review/source/#{audit.id}"))
    end

    it "focus lanes state each verdict's consequence" do
      examined!(claim!)
      get "/enliterator/review"
      expect(response.body).to include("becomes this claim&#39;s ground truth")   # confirm
        .and include("outranks it in every accuracy count")                       # overrule
        .and include("locked as a curator anchor")                                # correct
    end

    it "review/source returns the full source with the record's label" do
      audit = examined!(claim!)
      get "/enliterator/review/source/#{audit.id}"
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["text"]).to eq(widget.enliterator_text(facet: "summary"))
      expect(body["truncated"]).to be(false)
      expect(body["length"]).to eq(widget.enliterator_text(facet: "summary").length)
      expect(body["label"]).to eq("Acme")
      expect(body["key"]).to eq("summary")
    end

    it "review/source caps a huge source and says so" do
      audit = examined!(claim!)
      stub_const("Enliterator::ReviewController::SOURCE_CAP", 10)
      get "/enliterator/review/source/#{audit.id}"
      body = JSON.parse(response.body)
      expect(body["text"].length).to eq(10)
      expect(body["truncated"]).to be(true)
      expect(body["length"]).to eq(widget.enliterator_text(facet: "summary").length)
    end

    it "review/source labels an unreadable source instead of silently blanking it (rule 3)" do
      audit = examined!(claim!)
      allow_any_instance_of(Widget).to receive(:enliterator_text).and_raise(RuntimeError, "boom")
      get "/enliterator/review/source/#{audit.id}"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["error"]).to include("source unreadable").and include("boom")
    end

    it "review/source 404s an unknown audit" do
      get "/enliterator/review/source/999999"
      expect(response).to have_http_status(:not_found)
    end

    it "verdicts thread the focus param: success → focus_next, alert → focus_self, none → byte-identical" do
      audit = examined!(claim!)
      post "/enliterator/review/verdict",
           params: { audit_id: audit.id, decision: "confirm", focus_next: "77", focus_self: audit.id }
      expect(response).to redirect_to("/enliterator/review?focus=77")

      audit2 = examined!(claim!(key: "b"))
      post "/enliterator/review/verdict",
           params: { audit_id: audit2.id, decision: "overrule", verdict: "nonsense",
                     focus_next: "77", focus_self: audit2.id }
      expect(response).to redirect_to("/enliterator/review?focus=#{audit2.id}")   # alert reopens the item

      post "/enliterator/review/verdict", params: { audit_id: audit2.id, decision: "overrule", verdict: "supported" }
      expect(response).to redirect_to("/enliterator/review")                      # no param → identical
    end
  end

  describe "the Status accuracy panel (adoption-gated)" do
    it "is absent before any audit; present with rates after" do
      get "/enliterator/status"
      expect(response.body).not_to include("audited against its sources")

      examined!(claim!, verdict: "supported")
      get "/enliterator/status"
      expect(response.body).to include("audited against its sources")
        .and include("100%")
    end
  end
end
