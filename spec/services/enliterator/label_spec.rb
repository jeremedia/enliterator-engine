# frozen_string_literal: true

require "rails_helper"

# The one label contract (v0.62), narrow-select edition: batch lookups read ONLY the
# columns a label needs — host rows can be megabytes (extracted text), and loading
# them whole to read titles made Requests a four-second page. A model with a
# COMPUTED title declares its needs via `label_column_names` (Enliterator::Part).
RSpec.describe Enliterator::Label do
  let(:host) { Widget.create!(title: "Host Work", body: "y") }

  it "labels title-column hosts, computed-title parts, and misses honestly" do
    part  = Enliterator::Part.create!(record: host, ordinal: 1, heading: "Chapter One", text: "stored text")
    blank = Enliterator::Part.create!(record: host, ordinal: 2, heading: nil, text: "t")

    labels = described_class.for(
      [ [ "Widget", host.id ], [ "Enliterator::Part", part.id ],
        [ "Enliterator::Part", blank.id ], [ "Widget", 999_999 ] ]
    )

    expect(labels[[ "Widget", host.id ]][:title]).to eq("Host Work")
    expect(labels[[ "Enliterator::Part", part.id ]][:title]).to eq("Chapter One")
    expect(labels[[ "Enliterator::Part", blank.id ]][:title]).to eq("Section 2")
    expect(labels[[ "Widget", 999_999 ]][:title]).to eq("Widget #999999")
  end

  it "never loads a part's stored text for its label" do
    part = Enliterator::Part.create!(record: host, ordinal: 1, heading: "Ch", text: "fat stored text")

    part_queries = []
    cb = ->(*, payload) { part_queries << payload[:sql] if payload[:sql].to_s.match?(/SELECT.*enliterator_parts/im) }
    ActiveSupport::Notifications.subscribed(cb, "sql.active_record") do
      described_class.for([ [ "Enliterator::Part", part.id ] ])
    end

    expect(part_queries).not_to be_empty
    expect(part_queries.join).not_to include(%("text"))
  end
end
