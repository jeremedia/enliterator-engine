# frozen_string_literal: true
require "rails_helper"

RSpec.describe "Conversations browse + label", type: :request do
  after { Enliterator.configuration.chat_retention = nil }

  def make_conversation(label: nil)
    conv = Enliterator::Chat::Conversation.create!(token: SecureRandom.uuid, source: "live", label: label)
    conv.turns.create!(ordinal: 1, question: "What is this collection about?",
      events: [ { "event" => "token", "data" => { "t" => "It is about X." } },
                { "event" => "done",  "data" => {} } ])
    conv.turns.create!(ordinal: 2, question: "Tell me more.",
      events: [ { "event" => "token", "data" => { "t" => "More details." } },
                { "event" => "done",  "data" => {} } ])
    conv
  end

  it "404s on index when chat_retention is off" do
    Enliterator.configuration.chat_retention = nil
    get "/enliterator/conversations"
    expect(response).to have_http_status(:not_found)
  end

  it "404s on label when chat_retention is off" do
    Enliterator.configuration.chat_retention = nil
    conv = make_conversation
    post "/enliterator/conversations/#{conv.id}/label", params: { label: "My session" }
    expect(response).to have_http_status(:not_found)
  end

  it "404s on destroy when chat_retention is off" do
    Enliterator.configuration.chat_retention = nil
    conv = make_conversation
    post "/enliterator/conversations/#{conv.id}/delete"
    expect(response).to have_http_status(:not_found)
  end

  describe "when chat_retention is on" do
    before { Enliterator.configuration.chat_retention = true }

    it "index lists saved conversations with their label, turn count, and a Replay link" do
      conv = make_conversation(label: "Morning briefing")
      get "/enliterator/conversations"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Morning briefing")
      # Turn count (2 turns)
      expect(response.body).to include("2")
      # Replay link points to the chat page with the replay param (token)
      expect(response.body).to include("replay=#{conv.token}")
    end

    it "index shows (unlabeled) when no label is set" do
      make_conversation
      get "/enliterator/conversations"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("(unlabeled)")
    end

    it "label sets the conversation label and redirects" do
      conv = make_conversation
      post "/enliterator/conversations/#{conv.id}/label", params: { label: "FEDLINK demo" }
      expect(response).to redirect_to("/enliterator/conversations")
      expect(conv.reload.label).to eq("FEDLINK demo")
    end

    it "label clears the label when blank is submitted" do
      conv = make_conversation(label: "Old label")
      post "/enliterator/conversations/#{conv.id}/label", params: { label: "" }
      expect(response).to redirect_to("/enliterator/conversations")
      expect(conv.reload.label).to be_nil
    end

    it "destroy removes the conversation and redirects" do
      conv = make_conversation
      expect {
        post "/enliterator/conversations/#{conv.id}/delete"
      }.to change(Enliterator::Chat::Conversation, :count).by(-1)
      expect(response).to redirect_to("/enliterator/conversations")
    end
  end
end
