# frozen_string_literal: true
require "rails_helper"
RSpec.describe "Conversation replay", type: :request do
  after { Enliterator.configuration.chat_retention = nil }

  def make_conversation
    conv = Enliterator::Chat::Conversation.create!(token: "rtok", source: "live")
    conv.turns.create!(ordinal: 1, question: "q one",
      events: [ { "event" => "token", "data" => { "t" => "answer one" } },
                { "event" => "done",  "data" => {} } ])
    conv.turns.create!(ordinal: 2, question: "q two",
      events: [ { "event" => "followups", "data" => { "items" => [ "next?" ] } },
                { "event" => "done", "data" => {} } ])
    conv
  end

  it "404s when chat_retention is off" do
    Enliterator.configuration.chat_retention = nil
    conv = make_conversation
    get "/enliterator/chat/replay/#{conv.id}"
    expect(response).to have_http_status(:not_found)
  end

  it "re-emits the stored events with replay_user markers and replay_end (by id and by token)" do
    Enliterator.configuration.chat_retention = true
    conv = make_conversation
    get "/enliterator/chat/replay/#{conv.id}"
    body = response.body
    expect(body.scan("event: replay_user").size).to eq(2)   # one per turn
    expect(body).to include("q one").and include("q two")
    expect(body).to include("answer one")
    expect(body).to include("event: followups")
    expect(body).to include("event: replay_end")
    # also resolvable by token
    get "/enliterator/chat/replay/rtok"
    expect(response.body).to include("event: replay_user")
  end

  it "404s for an unknown id/token" do
    Enliterator.configuration.chat_retention = true
    get "/enliterator/chat/replay/nope"
    expect(response).to have_http_status(:not_found)
  end
end
