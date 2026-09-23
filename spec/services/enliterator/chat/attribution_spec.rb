# frozen_string_literal: true

require "rails_helper"

# v0.79 — attribution discipline (config.chat_attribution). The 2026-09-21 desk A/B
# found the enliterated desk restating verified claims as the author's words,
# splicing quotations and reciting audit rates (content fabrication .55 vs .14–.20
# for a raw-search agent on the same model). Flag OFF must be byte-identical
# everywhere; flag ON separates the catalog's claim from the document's text.
RSpec.describe "Chat attribution (v0.79)" do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  after { Enliterator.configuration.chat_attribution = nil }

  def enliterate!(title, body: "b", **claims)
    w = Widget.create!(title: title, body: body)
    claims.each do |key, value|
      visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
      w.enliterator_claims.create!(key: key.to_s, value: value, status: "draft", confidence: 0.8, visit: visit)
    end
    w.enliterator_embeddings.create!(kind: "primary", embedding: embedder.embed(w.enliterator_text),
                                     dimensions: embedder.dimensions, model: "null")
    w
  end

  def call_tool(name, **args) = Enliterator::Mcp.dispatch(name, args.transform_keys(&:to_s))

  def recording_llm
    Class.new do
      define_method(:converse_with_tools) do |messages:, tools:, stream: false, **|
        @seen = messages.first["content"]
        Enliterator::Adapters::LLM::Gateway::ToolTurn.new(text: "An answer.", tool_calls: [],
                                                          assistant_message: nil, tokens: {})
      end
      attr_reader :seen
    end.new
  end

  let(:agent) do
    Enliterator::Chat::Agent.new(name: "Desk", grounding: nil, system_prompt: "You are the Desk.",
                                 tools: %w[search], tier: "cheap", routes_to: [])
  end

  describe "the system content" do
    it "is byte-identical with the flag off" do
      expect(Enliterator::Chat.compose_system("You are the Desk.")).to eq("You are the Desk.")
    end

    it "appends the directive after the persona and before the follow-up directive" do
      Enliterator.configuration.chat_attribution = true
      Enliterator.configuration.chat_followups = true
      llm = recording_llm
      Enliterator::Chat::Loop.new(agent: agent, llm: llm, sink: ->(*) {}).run("hi")
      per = llm.seen.index("You are the Desk.")
      att = llm.seen.index("Attribution.")
      fol = llm.seen.index(Enliterator::Chat::Followups::SENTINEL)
      expect([ per, att, fol ]).to all(be_truthy)
      expect(per).to be < att
      expect(att).to be < fol
    ensure
      Enliterator.configuration.chat_followups = nil
    end

    it "rides the handoff to the specialist that answers" do
      Enliterator::Chat.reset!
      allow(Enliterator).to receive(:llm).and_return(double(converse_with_tools: nil))
      Enliterator::Chat.register(name: "F", grounding: nil, system_prompt: "p", tools: %w[search],
                                 tier: "cheap", routes_to: %w[CHDS])
      Enliterator::Chat.register(name: "CHDS", grounding: "chds-theses", system_prompt: "advise",
                                 tools: %w[search], tier: "cheap")
      Enliterator.configuration.chat_attribution = true
      seen_on_final = nil
      turns = [ Enliterator::Adapters::LLM::Gateway::ToolTurn.new(
                  text: nil, tool_calls: [ { id: "1", name: "route_to", arguments: { "agent" => "CHDS" } } ],
                  assistant_message: nil, tokens: {}),
                "An answer." ]
      llm = Object.new
      llm.define_singleton_method(:converse_with_tools) do |messages:, tools:, stream: false, **|
        t = turns.shift
        next t if t.is_a?(Enliterator::Adapters::LLM::Gateway::ToolTurn)
        seen_on_final = messages.first["content"]
        Enliterator::Adapters::LLM::Gateway::ToolTurn.new(text: t, tool_calls: [], assistant_message: nil, tokens: {})
      end
      Enliterator::Chat::Loop.new(agent: Enliterator::Chat.frontdesk, llm: llm, sink: ->(*) {}, step_cap: 4).run("hi")
      expect(seen_on_final).to include("advise")
      expect(seen_on_final).to include(Enliterator::Chat::Attribution::DIRECTIVE)
    ensure
      Enliterator::Chat.reset!
    end
  end

  describe "claim cards" do
    it "carry no nature flag-off, and name the catalog's claim flag-on" do
      w = enliterate!("A", advisor: "Dr. Voss")
      off = call_tool("record_entry", type: "Widget", id: w.id.to_s)[:claims]["summary"].first
      expect(off).not_to have_key(:nature)

      Enliterator.configuration.chat_attribution = true
      on = call_tool("record_entry", type: "Widget", id: w.id.to_s)[:claims]["summary"].first
      expect(on[:nature]).to eq("catalog_claim")
    end

    it "names a host-seeded claim as the host's assertion, not the catalog's reading" do
      Enliterator.configuration.chat_attribution = true
      w = enliterate!("Seeded")
      w.enliterator_claims.create!(key: "accession", value: "X-1", status: "verified", confidence: 1.0)
      card = call_tool("record_entry", type: "Widget", id: w.id.to_s)[:claims]["asserted"].first
      expect(card[:nature]).to eq("host_assertion")
    end
  end

  describe "quote" do
    let(:body) { "The clerks kept counting through redundant tabulation systems and statutory fallback procedures." }

    it "keeps the pre-v0.79 shape flag-off" do
      w = enliterate!("Q", body: body, finding: "redundant tabulation systems and statutory fallback procedures")
      out = call_tool("quote", claim_id: w.enliterator_claims.find_by(key: "finding").id)
      expect(out.keys).to include(:claim, :passage, :located)
      expect(out.keys).not_to include(:catalog_claim, :source_passage, :verbatim)
    end

    it "names the catalog's claim and the document's own text apart flag-on" do
      Enliterator.configuration.chat_attribution = true
      w = enliterate!("Q", body: body, finding: "redundant tabulation systems and statutory fallback procedures",
                           alien: "an assertion about volcanoes the source never makes")
      found = call_tool("quote", claim_id: w.enliterator_claims.find_by(key: "finding").id)
      expect(found[:catalog_claim]).to include(key: "finding", nature: "catalog_claim")
      expect(found[:source_passage]).to include("redundant tabulation")
      expect(found[:verbatim]).to be(true)
      expect(found.keys).not_to include(:claim, :passage)

      lost = call_tool("quote", claim_id: w.enliterator_claims.find_by(key: "alien").id)
      expect(lost[:verbatim]).to be(false)
    end

    it "still renders in the reading room under either key" do
      html = Enliterator::Chat::Widget.render("quote", { source_passage: "the document's words", located: true })
      expect(html).to include("the document&#39;s words").or include("the document's words")
    end
  end

  describe "accuracy figures" do
    it "the tool description stops asking the agent to say them out loud" do
      desc = -> { Enliterator::Mcp.listing.find { |t| t[:name] == "accuracy" }[:description] }
      expect(desc.call).to include("say them out loud")
      Enliterator.configuration.chat_attribution = true
      expect(desc.call).not_to include("out loud")
      expect(desc.call).to include("only when they ask how reliable")
    end

    it "collection_overview keeps its accuracy rows flag-off and drops them flag-on" do
      expect(call_tool("collection_overview")).to have_key(:accuracy)
      Enliterator.configuration.chat_attribution = true
      expect(call_tool("collection_overview")).not_to have_key(:accuracy)
      expect(call_tool("accuracy")).to have_key(:by_facet_and_tier)   # one call away
    end
  end
end
