# frozen_string_literal: true
require "rails_helper"

RSpec.describe "Desks (persona editing)", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
      c.llm_adapter = Class.new do
        def model_id = "stub"
        def converse_with_tools(**) = Enliterator::Adapters::LLM::Gateway::ToolTurn.new(text: "x", tool_calls: [], assistant_message: nil, tokens: {})
      end.new
    end
    Enliterator::Chat.reset!
    Enliterator::Chat.register(name: "Frontdesk", grounding: nil, system_prompt: "SEED front.",
                              tools: %w[search], tier: "cheap")
  end
  after do
    Enliterator.configuration.chat_persona_editing = nil
    Enliterator.configuration.chat_editor = nil
    Enliterator::Chat.reset!
  end

  it "404s when chat_persona_editing is off" do
    Enliterator.configuration.chat_persona_editing = nil
    get "/enliterator/desks"
    expect(response).to have_http_status(:not_found)
  end

  it "lists the registered desks when on" do
    Enliterator.configuration.chat_persona_editing = true
    get "/enliterator/desks"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Frontdesk")
    expect(response.body).to include("SEED front.")  # the effective (seed) persona is shown
  end

  it "saves a new persona version and the effective text changes" do
    Enliterator.configuration.chat_persona_editing = true
    post "/enliterator/desks/update", params: { desk: "Frontdesk", system_prompt: "EDITED front." }
    expect(response).to redirect_to("/enliterator/desks")
    expect(Enliterator::Chat::Persona.effective("Frontdesk")).to eq("EDITED front.")
  end

  it "rejects a blank persona (rule 3)" do
    Enliterator.configuration.chat_persona_editing = true
    post "/enliterator/desks/update", params: { desk: "Frontdesk", system_prompt: "   " }
    expect(Enliterator::Chat::Persona.effective("Frontdesk")).to be_nil
    follow_redirect!
    expect(response.body).to include("can&#39;t be blank").or include("can't be blank")
  end

  it "rolls back to a prior version by appending a new version with that text" do
    Enliterator.configuration.chat_persona_editing = true
    v1 = Enliterator::Chat::Persona.record(desk_name: "Frontdesk", system_prompt: "V1.")
    Enliterator::Chat::Persona.record(desk_name: "Frontdesk", system_prompt: "V2.")
    post "/enliterator/desks/rollback", params: { desk: "Frontdesk", version_id: v1.id }
    expect(Enliterator::Chat::Persona.effective("Frontdesk")).to eq("V1.")
    expect(Enliterator::Chat::Persona.history("Frontdesk").count).to eq(3)  # append-only
  end

  it "records the editor via config.chat_editor when set" do
    Enliterator.configuration.chat_persona_editing = true
    Enliterator.configuration.chat_editor = ->(_req) { "curator@example.gov" }
    post "/enliterator/desks/update", params: { desk: "Frontdesk", system_prompt: "X." }
    expect(Enliterator::Chat::Persona.history("Frontdesk").first.editor).to eq("curator@example.gov")
  end
end
