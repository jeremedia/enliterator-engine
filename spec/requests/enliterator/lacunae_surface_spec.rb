# frozen_string_literal: true

require "rails_helper"

# v0.46: the lacunae surfaces — the record-page "Known gaps" panel, the Status
# rollup, and the MCP `lacunae` tool. All render only on data, so an unadopted
# host is byte-identical.
RSpec.describe "Enliterator lacunae surfaces", type: :request do
  let(:widget) { Widget.create!(title: "Thesis", body: "b") }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap", "quality" ]
      end
    end
  end

  def open_lacuna!(key, **opts)
    Enliterator::Lacuna.open_or_refresh(tendable: widget, facet: "authorship", key: key, **opts)
  end

  describe "record page — the Known gaps panel" do
    it "renders the panel when the record has open lacunae (with diagnosis + note)" do
      open_lacuna!("authored_by", diagnosis: "defective_surrogate", note: "byline dropped")
      get "/enliterator/status/Widget/#{widget.id}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Known gaps").and include("authored_by")
                          .and include("defective_surrogate").and include("byline dropped")
    end

    it "renders an undiagnosed gap with a nil note gracefully (the core shape)" do
      open_lacuna!("authored_by") # undiagnosed, no note
      get "/enliterator/status/Widget/#{widget.id}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Known gaps").and include("undiagnosed")
    end

    it "omits the panel when the record has no open lacunae" do
      get "/enliterator/status/Widget/#{widget.id}"
      expect(response.body).not_to include("Known gaps")
    end
  end

  describe "status rollup — the Known gaps overview" do
    it "renders the rollup grouped by facet when any open lacuna exists" do
      open_lacuna!("authored_by")
      get "/enliterator/status"
      expect(response.body).to include("what the collection knows it's missing").and include("authorship")
    end

    it "omits the rollup when there are no open lacunae (byte-identical off)" do
      get "/enliterator/status"
      expect(response.body).not_to include("what the collection knows it's missing")
    end
  end

  describe "MCP lacunae tool" do
    it "is listed in the tools surface" do
      expect(Enliterator::Mcp.listing.map { |t| t[:name] }).to include("lacunae")
    end

    it "returns the rollup + a bounded sample" do
      open_lacuna!("authored_by", diagnosis: "defective_surrogate")
      out = Enliterator::Mcp.dispatch("lacunae", {})
      expect(out[:open_total]).to eq(1)
      expect(out[:by_facet]).to eq({ "authorship" => 1 })
      expect(out[:sample].first).to include(type: "Widget", key: "authored_by", diagnosis: "defective_surrogate")
      expect(out[:next]).to be_present
    end

    it "is empty (open_total 0, no sample) when there are no open lacunae" do
      out = Enliterator::Mcp.dispatch("lacunae", {})
      expect(out[:open_total]).to eq(0)
      expect(out[:sample]).to eq([])
    end
  end
end
