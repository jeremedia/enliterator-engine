# spec/services/enliterator/chat/followups_spec.rb
# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Chat::Followups do
  def tail(*lines) = "An answer here.\n\n#{described_class::SENTINEL}\n#{lines.join("\n")}"

  it "parses up to three clean questions after the sentinel" do
    qs = described_class.parse(tail("What changed?", "Who cited it?", "How does it connect?"))
    expect(qs).to eq([ "What changed?", "Who cited it?", "How does it connect?" ])
  end

  it "returns [] when the sentinel is absent (model omitted the block)" do
    expect(described_class.parse("Just an answer, no block.")).to eq([])
  end

  it "caps at three even if the model emits more" do
    qs = described_class.parse(tail("a?", "b?", "c?", "d?", "e?"))
    expect(qs).to eq([ "a?", "b?", "c?" ])
  end

  it "strips bullet/number prefixes and drops blank lines" do
    qs = described_class.parse(tail("- First?", "", "2. Second?", "  * Third?  "))
    expect(qs).to eq([ "First?", "Second?", "Third?" ])
  end

  it "returns [] when the sentinel is present but nothing follows" do
    expect(described_class.parse("Answer.\n\n#{described_class::SENTINEL}\n")).to eq([])
  end

  it "uses the suffix after the FIRST sentinel occurrence" do
    text = "Answer.\n\n#{described_class::SENTINEL}\nOnly?\n#{described_class::SENTINEL}\nNope?"
    expect(described_class.parse(text)).to eq([ "Only?" ])
  end

  it "tolerates CRLF and trailing whitespace" do
    text = "Answer.\r\n\r\n#{described_class::SENTINEL}\r\nQ one?\r\nQ two?\r\n"
    expect(described_class.parse(text)).to eq([ "Q one?", "Q two?" ])
  end

  it "exposes a DIRECTIVE string that names the sentinel literally" do
    expect(described_class::DIRECTIVE).to include(described_class::SENTINEL)
  end
end
