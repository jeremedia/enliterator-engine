# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Conversation do
  it "requires token" do
    conv = described_class.new(token: nil)
    expect(conv).not_to be_valid
    expect(conv.errors[:token]).to be_present
  end

  it "enforces token uniqueness" do
    described_class.create!(token: "abc-123")
    dup = described_class.new(token: "abc-123")
    expect(dup).not_to be_valid
    expect(dup.errors[:token]).to be_present
  end

  it "has many turns ordered by ordinal" do
    conv = described_class.create!(token: "t1")
    t2 = conv.turns.create!(ordinal: 2, question: "second?")
    t1 = conv.turns.create!(ordinal: 1, question: "first?")
    expect(conv.turns.to_a).to eq([ t1, t2 ])
  end

  it "destroys turns when conversation is destroyed" do
    conv = described_class.create!(token: "t2")
    conv.turns.create!(ordinal: 1, question: "q?")
    expect { conv.destroy }.to change(Enliterator::Chat::Turn, :count).by(-1)
  end
end
