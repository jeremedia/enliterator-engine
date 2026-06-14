# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Persona do
  it "effective returns nil when no version is stored" do
    expect(described_class.effective("CHDS Theses")).to be_nil
  end

  it "record appends a version and effective returns the latest text" do
    described_class.record(desk_name: "CHDS Theses", system_prompt: "v1 text")
    described_class.record(desk_name: "CHDS Theses", system_prompt: "v2 text", editor: "alice", note: "tighten")
    expect(described_class.effective("CHDS Theses")).to eq("v2 text")
  end

  it "scopes effective per desk" do
    described_class.record(desk_name: "Frontdesk", system_prompt: "front")
    described_class.record(desk_name: "CHDS Theses", system_prompt: "chds")
    expect(described_class.effective("Frontdesk")).to eq("front")
    expect(described_class.effective("CHDS Theses")).to eq("chds")
  end

  it "history is newest-first and carries editor/note" do
    described_class.record(desk_name: "Frontdesk", system_prompt: "a")
    described_class.record(desk_name: "Frontdesk", system_prompt: "b", editor: "bob", note: "n")
    h = described_class.history("Frontdesk").to_a
    expect(h.map(&:system_prompt)).to eq(%w[b a])
    expect(h.first.editor).to eq("bob")
    expect(h.first.note).to eq("n")
  end

  it "requires desk_name and system_prompt" do
    expect { described_class.record(desk_name: "X", system_prompt: "") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
