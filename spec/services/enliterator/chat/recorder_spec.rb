# frozen_string_literal: true

require "rails_helper"

RSpec.describe Enliterator::Chat::Recorder do
  let(:conv) { Enliterator::Chat::Conversation.create!(token: "t1", source: "live") }

  S = Enliterator::Chat::Followups::SENTINEL

  it "records a turn, deriving answer/desk from the events (string outer + symbol data keys)" do
    events = [
      { "event" => "handoff", "data" => { to: "CHDS Theses" } },
      { "event" => "token",   "data" => { t: "From the collection. " } },
      { "event" => "token",   "data" => { t: "Done.\n\n#{S}\nWhat next?" } },
    ]
    turn = described_class.record(
      conversation: conv,
      question: "hi",
      events: events,
      initial_desk: "Frontdesk",
      elapsed_ms: 1200
    )
    expect(turn).to be_persisted
    expect(turn.ordinal).to eq(1)
    expect(turn.answer).to eq("From the collection. Done.")
    expect(turn.desk_name).to eq("CHDS Theses")
    expect(turn.elapsed_ms).to eq(1200)
    expect(turn.budget_hit).to be(false)
  end

  it "uses initial_desk when no handoff, links persona_id, increments ordinal" do
    Enliterator::Chat::Persona.record(desk_name: "Frontdesk", system_prompt: "p")
    pid = Enliterator::Chat::Persona.history("Frontdesk").first.id

    described_class.record(
      conversation: conv,
      question: "q1",
      events: [{ "event" => "token", "data" => { t: "a" } }],
      initial_desk: "Frontdesk"
    )
    t2 = described_class.record(
      conversation: conv,
      question: "q2",
      events: [{ "event" => "token", "data" => { t: "b" } }],
      initial_desk: "Frontdesk"
    )
    expect(t2.ordinal).to eq(2)
    expect(t2.desk_name).to eq("Frontdesk")
    expect(t2.persona_id).to eq(pid)
  end

  it "persona_id is nil when no persona recorded for the desk" do
    turn = described_class.record(
      conversation: conv,
      question: "q",
      events: [{ "event" => "token", "data" => { t: "answer" } }],
      initial_desk: "UnknownDesk"
    )
    expect(turn.persona_id).to be_nil
  end

  it "flags budget_hit and tolerates fully-string-keyed (jsonb) events" do
    events = [
      { "event" => "token", "data" => { "t" => "I reached my step budget — here is what I have so far." } }
    ]
    turn = described_class.record(
      conversation: conv,
      question: "hi",
      events: events,
      initial_desk: "Frontdesk"
    )
    expect(turn.budget_hit).to be(true)
    expect(turn.answer).to include("step budget")
  end

  it "flags budget_hit for 'time budget' phrase as well" do
    events = [{ "event" => "token", "data" => { "t" => "time budget reached." } }]
    turn = described_class.record(conversation: conv, question: "hi", events: events, initial_desk: "D")
    expect(turn.budget_hit).to be(true)
  end

  it "uses the LAST handoff's desk when multiple handoffs are present" do
    events = [
      { "event" => "handoff", "data" => { to: "Desk A" } },
      { "event" => "token",   "data" => { t: "first" } },
      { "event" => "handoff", "data" => { to: "Desk B" } },
      { "event" => "token",   "data" => { t: " second" } },
    ]
    turn = described_class.record(conversation: conv, question: "hi", events: events, initial_desk: "Frontdesk")
    expect(turn.desk_name).to eq("Desk B")
  end

  it "never raises on a malformed events array" do
    expect do
      described_class.record(
        conversation: conv,
        question: "hi",
        events: [{}, "garbage", nil],
        initial_desk: "Frontdesk"
      )
    end.not_to raise_error
  end

  it "stores the raw events array on the turn" do
    events = [{ "event" => "token", "data" => { t: "hello" } }]
    turn = described_class.record(conversation: conv, question: "q", events: events, initial_desk: "D")
    expect(turn.events).to be_present
  end

  it "returns nil (not raise) when the record cannot be created" do
    # Force a create! failure by passing a nil question (violates presence validation)
    result = nil
    expect do
      result = described_class.record(
        conversation: conv,
        question: nil,
        events: [],
        initial_desk: "D"
      )
    end.not_to raise_error
    expect(result).to be_nil
  end
end
