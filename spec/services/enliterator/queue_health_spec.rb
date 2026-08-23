# frozen_string_literal: true

require "rails_helper"

# v0.72.4 — loud enqueue. The failure closed: 32 jobs in a consumerless queue,
# silently, indefinitely. The probe is adapter-FIRST (gem presence proves
# nothing), compares the CONFIGURED queue name (the job class attribute is a
# block-form Proc), always RETURNS the warning (only the log is rate-limited),
# and never, ever raises.
RSpec.describe Enliterator::QueueHealth do
  before { described_class.reset! }

  # An enumerable stand-in for Sidekiq::ProcessSet.
  def fake_process_set(rows)
    Class.new do
      define_singleton_method(:rows) { rows }
      include Enumerable
      define_method(:each) { |&b| self.class.rows.each(&b) }
      def self.name = "Sidekiq::ProcessSet"
    end
  end

  it "is nil (unknown, SILENT) on a non-sidekiq adapter — even with the gem bundled" do
    # The dummy app runs the :test adapter; merely having the constant around
    # (a host that bundles sidekiq while running solid_queue) must not warn.
    stub_const("Sidekiq::ProcessSet", fake_process_set([]))
    expect(Enliterator::TendingVisitJob.queue_adapter_name).not_to eq("sidekiq")
    expect(described_class.consumer_listening?).to be_nil
    expect(described_class.warn_if_unconsumed).to be_nil
  end

  context "on the sidekiq adapter" do
    before do
      allow(Enliterator::TendingVisitJob).to receive(:queue_adapter_name).and_return("sidekiq")
    end

    it "compares the CONFIGURED queue name as a string — never the class attribute (a Proc)" do
      # The trap: `queue_as { … }` makes TendingVisitJob.queue_name a Proc whose
      # to_s matches no Sidekiq queue ever — a false "no consumer" on every
      # correctly-running host, the inverse of the rule-3 fix this is.
      expect(Enliterator::TendingVisitJob.queue_name).not_to be_a(String)
      expect(Enliterator.configuration.queue_name.to_s).to eq("enliterator")

      stub_const("Sidekiq::ProcessSet", fake_process_set([ { "queues" => %w[default enliterator] } ]))
      expect(described_class.consumer_listening?).to be(true)
      expect(described_class.warn_if_unconsumed).to be_nil

      stub_const("Sidekiq::ProcessSet", fake_process_set([ { "queues" => %w[default] } ]))
      expect(described_class.consumer_listening?).to be(false)
    end

    it "RETURNS the warning on every call; only the LOG is rate-limited" do
      # A heartbeat ledger appending the return must get it every cycle — a
      # warn-once that swallowed cycle 2's string would leave that cycle's
      # run_warnings incomplete while the queue still has no consumer.
      stub_const("Sidekiq::ProcessSet", fake_process_set([]))
      logger = instance_double(ActiveSupport::Logger)
      allow(Enliterator.configuration).to receive(:logger).and_return(logger)
      expect(logger).to receive(:warn).once.with(/queue_unconsumed/)

      w1 = described_class.warn_if_unconsumed(context: "heartbeat 1")
      w2 = described_class.warn_if_unconsumed(context: "heartbeat 2")
      expect(w1).to include("no Sidekiq worker", "enliterator", "heartbeat 1")
      expect(w2).to include("heartbeat 2")
    end

    it "never raises from a broken probe — a liveness check must not break an enqueue" do
      broken = Class.new { def initialize = raise("redis down") }
      stub_const("Sidekiq::ProcessSet", broken)
      expect(described_class.consumer_listening?).to be_nil
      expect(described_class.warn_if_unconsumed).to be_nil
    end
  end
end
