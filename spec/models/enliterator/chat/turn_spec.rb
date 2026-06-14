# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Turn do
  let(:conversation) { Enliterator::Chat::Conversation.create!(token: "turn-conv-#{rand(9999)}") }

  it "requires question" do
    turn = described_class.new(conversation: conversation, ordinal: 1, question: "")
    expect(turn).not_to be_valid
    expect(turn.errors[:question]).to be_present
  end

  it "belongs to conversation" do
    turn = described_class.create!(conversation: conversation, ordinal: 1, question: "What is SKOS?")
    expect(turn.conversation).to eq(conversation)
  end

  it "allows nil persona (optional belongs_to)" do
    turn = described_class.new(conversation: conversation, ordinal: 1, question: "q?", persona_id: nil)
    expect(turn).to be_valid
  end

  it "round-trips events as an array of hashes" do
    payload = [ { "event" => "token", "data" => { "t" => "hi" } } ]
    turn = described_class.create!(conversation: conversation, ordinal: 1, question: "q?", events: payload)
    reloaded = described_class.find(turn.id)
    expect(reloaded.events).to eq(payload)
  end

  it "defaults events to an empty array" do
    turn = described_class.create!(conversation: conversation, ordinal: 1, question: "q?")
    expect(turn.events).to eq([])
  end
end
