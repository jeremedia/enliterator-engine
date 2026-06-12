# frozen_string_literal: true
require "rails_helper"

RSpec.describe Enliterator::Mcp::Tools::Connections do
  it "labels neighbors_state 'no_embedding' when the record has no stored primary embedding" do
    w = Widget.create!(title: "Unembedded", body: "b")   # dummy host record, no embedding row
    out = Enliterator::Mcp.dispatch("connections", { "type" => "Widget", "id" => w.id.to_s })
    expect(out[:neighbors]).to eq([])
    expect(out[:neighbors_state]).to eq("no_embedding")
  end

  it "labels neighbors_state 'ok' when the record has a stored primary embedding" do
    embedder = Enliterator::Adapters::Embedder::Null.new
    w = Widget.create!(title: "Embedded", body: "b")
    w.enliterator_embeddings.create!(kind: "primary", embedding: embedder.embed(w.enliterator_text),
                                     dimensions: embedder.dimensions, model: "null")
    out = Enliterator::Mcp.dispatch("connections", { "type" => "Widget", "id" => w.id.to_s })
    expect(out[:neighbors_state]).to eq("ok")
  end
end
