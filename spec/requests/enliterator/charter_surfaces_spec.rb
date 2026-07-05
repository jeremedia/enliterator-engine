# frozen_string_literal: true

require "rails_helper"

# v0.57 — the charter on every reader-facing surface, and its literal ABSENCE
# when unconfigured (the byte-identity half of each assertion).
RSpec.describe "Charter surfaces", type: :request do
  let!(:library) { Library.create!(name: "Test Library") }

  def tell_charter!
    Enliterator.configure { |c| c.collection_tendable = "Library" }
    Enliterator::Charter.tell!(
      proper_noun: "Spine", identity: "a workshop of sovereign manuscripts",
      purpose: "writing and tending books", audience: "authors and their AI collaborators",
      by: "jeremy"
    )
  end

  describe "collection_overview MCP tool" do
    it "leads with the charter when told, with the record-entry hint" do
      tell_charter!
      result = Enliterator::Mcp.dispatch("collection_overview", {})
      expect(result.keys.first).to eq(:charter)
      expect(result[:charter][:proper_noun]).to eq("Spine")
      expect(result[:charter][:untold]).to eq([])
      expect(result[:charter][:derived]).to have_key(:reading_scope)
      expect(result[:charter][:record_entry_hint]).to include("Library")
    end

    it "carries the untold list while onboarding is incomplete" do
      Enliterator.configure { |c| c.collection_tendable = "Library" }
      Enliterator::Charter.tell!(proper_noun: "Spine")
      result = Enliterator::Mcp.dispatch("collection_overview", {})
      expect(result[:charter][:untold]).to contain_exactly("identity", "purpose", "audience")
    end

    it "has NO charter key when unconfigured — the pre-charter payload shape" do
      result = Enliterator::Mcp.dispatch("collection_overview", {})
      expect(result).not_to have_key(:charter)
    end
  end

  describe "record_entry bucketing" do
    it "groups charter claims under 'charter', other seeds under 'asserted'" do
      tell_charter!
      library.assert_claim!(key: "founded", value: "2026")
      result = Enliterator::Mcp.dispatch("record_entry", { "type" => "Library", "id" => library.id.to_s })
      expect(result[:claims].keys).to include("charter", "asserted")
      expect(result[:claims]["charter"].map { |c| c[:key] }).to include("charter_proper_noun")
      expect(result[:claims]["asserted"].map { |c| c[:key] }).to eq([ "founded" ])
    end
  end

  describe "Status header" do
    it "leads with the told identity" do
      tell_charter!
      get "/enliterator/status"
      expect(response.body).to include("Spine — a workshop of sovereign manuscripts")
    end

    it "is the plain finding-aid header when unconfigured" do
      get "/enliterator/status"
      expect(response.body).to include("<h1>Status <span")
      expect(response.body).not_to include("workshop of sovereign")
    end
  end

  describe "chat composition (both modes)" do
    it "compose_system carries the charter block independent of chat_register" do
      tell_charter!
      composed = Enliterator::Chat.compose_system("You are the Desk.")
      expect(composed).to start_with("This collection is Spine — a workshop of sovereign manuscripts.")
      expect(composed).to include("Its purpose: writing and tending books.")
      expect(composed).to end_with("You are the Desk.")
    end

    it "compose_system is byte-identical without a charter" do
      expect(Enliterator::Chat.compose_system("You are the Desk.")).to eq("You are the Desk.")
    end

    it "Synopsis to_prompt names the collection (the single-shot grounding seam)" do
      tell_charter!
      prompt = Enliterator::Synopsis.to_prompt(Enliterator::Synopsis.build)
      expect(prompt).to start_with("COLLECTION SELF-PORTRAIT — Spine: a workshop of sovereign manuscripts")
    end

    it "Synopsis to_prompt header is bare without a charter" do
      prompt = Enliterator::Synopsis.to_prompt(Enliterator::Synopsis.build)
      expect(prompt).to start_with("COLLECTION SELF-PORTRAIT\n")
    end
  end

  describe "Catalog subject browse" do
    it "excludes charter_* keys from headings while subject_search still resolves them" do
      tell_charter!
      headings = Enliterator::Catalog.new.overview[:headings]
      expect(headings.map { |h| h[:key] }).not_to include(a_string_starting_with("charter_"))

      hits = Enliterator::Mcp.dispatch("subject_search",
                                       { "key" => "charter_proper_noun", "value" => "Spine" })
      expect(hits[:records].map { |r| r[:id] }).to include(library.id.to_s)
    end
  end

  describe "lacunae surfaces render the visit-less charter gap" do
    it "shows on the record page Known-gaps panel" do
      Enliterator.configure { |c| c.collection_tendable = "Library" }
      Enliterator::Charter.reconcile_gaps!
      get "/enliterator/status/Library/#{library.id}"
      expect(response.body).to include("Known gaps")
      expect(response.body).to include("charter_proper_noun")
      expect(response.body).to include("silent")
    end
  end
end
