# frozen_string_literal: true

require "rails_helper"

# v0.69 — host-contributed MCP tools.
#
# The engine's tools read the collection; a host application has actions of its
# own that belong in the same conversation. This is the registry that lets it
# say so, mirroring Measures.register / Condition.register.
#
# The load-bearing pin is the FIRST one: with nothing registered, every
# existing consumer must see exactly what it saw before. mcp_protocol_spec
# asserts a tool count, so a leak here would make that spec order-dependent.
RSpec.describe Enliterator::Mcp, ".register" do
  # A minimal well-formed host tool, defined the way a host would.
  let(:host_tool) do
    Class.new(Enliterator::Mcp::Tool) do
      name_and_description "host_probe", "A host-owned probe."
      schema({ "note" => str("anything") }, required: [])

      def call(note: nil) = { echoed: note, next: { human_view: "/probe" } }
    end
  end

  after { described_class.reset_host_tools! }

  describe "back-compatibility" do
    it "with nothing registered, the listing is unchanged" do
      expect(described_class.host_tool_classes).to be_empty
      expect(described_class.tool_classes).to eq(described_class.builtin_tool_classes)
      expect(described_class.listing.size).to eq(15)
    end

    it "keeps the engine's tools first and in their original order" do
      before_names = described_class.listing.map { |t| t[:name] }
      described_class.register(host_tool)

      expect(described_class.listing.map { |t| t[:name] }.first(15)).to eq(before_names)
      expect(described_class.listing.last[:name]).to eq("host_probe")
    end

    it "reset_host_tools! restores the baseline" do
      described_class.register(host_tool)
      expect(described_class.listing.size).to eq(16)

      described_class.reset_host_tools!

      expect(described_class.listing.size).to eq(15)
      expect(described_class.find_tool("host_probe")).to be_nil
    end
  end

  describe "a registered tool" do
    before { described_class.register(host_tool) }

    it "appears in the listing with its schema" do
      entry = described_class.listing.find { |t| t[:name] == "host_probe" }
      expect(entry[:description]).to eq("A host-owned probe.")
      expect(entry[:inputSchema]["properties"]).to have_key("note")
    end

    it "is dispatchable, and validated like any engine tool" do
      expect(described_class.dispatch("host_probe", { "note" => "hi" })).to include(echoed: "hi")

      # Unknown keys are rejected by the shared validator — a host tool gets no
      # special treatment at the door.
      expect { described_class.dispatch("host_probe", { "bogus" => 1 }) }
        .to raise_error(Enliterator::Mcp::InvalidArguments)
    end

    it "is reachable through find_tool" do
      expect(described_class.find_tool("host_probe")).to eq(host_tool)
    end
  end

  describe "registration validation" do
    it "refuses a class that is not a tool" do
      expect { described_class.register(Class.new) }
        .to raise_error(Enliterator::ConfigurationError, /does not respond to/)
    end

    it "refuses a blank tool_name" do
      nameless = Class.new(Enliterator::Mcp::Tool) do
        name_and_description "", "no name"
        schema({}, required: [])
      end
      expect { described_class.register(nameless) }
        .to raise_error(Enliterator::ConfigurationError, /blank tool_name/)
    end

    it "refuses a name that collides with an engine tool" do
      impostor = Class.new(Enliterator::Mcp::Tool) do
        name_and_description "search", "shadows the engine's search"
        schema({}, required: [])
      end
      expect { described_class.register(impostor) }
        .to raise_error(Enliterator::ConfigurationError, /collides/)
      expect(described_class.find_tool("search")).to eq(Enliterator::Mcp::Tools::Search)
    end

    it "replaces rather than duplicates on re-registration" do
      # The normal case across a dev reload: the host re-registers every
      # to_prepare. The listing must not grow each time.
      described_class.register(host_tool)
      described_class.register(host_tool)

      expect(described_class.listing.count { |t| t[:name] == "host_probe" }).to eq(1)
    end
  end

  describe "the doctrine" do
    it "still routes the engine's own writes through the governed queues" do
      # Host tools do not loosen this: propose_term and flag_claim remain the
      # only engine writes, and they queue rather than edit.
      expect(described_class.builtin_tool_classes).to include(
        Enliterator::Mcp::Tools::ProposeTerm, Enliterator::Mcp::Tools::FlagClaim
      )
    end
  end
end
