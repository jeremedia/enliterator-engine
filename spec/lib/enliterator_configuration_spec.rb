# frozen_string_literal: true

require "rails_helper"

# v0.30 actionable error reporting — Task 1: the error_detail config flag and its
# resolver. A 3-state switch (nil = auto, true = force on, false = force off) that
# decides whether ACTIONABLE error detail (exception class/message, where, a
# remediation hint) is surfaced to the chat frontend. The auto predicate is
# env-derived (on in dev) but host-overridable via error_detail_auto= so a strictly
# env-policy-free host can replace it.
#
# The env read is live (not memoized) — these examples flip Rails.env between
# assertions and expect error_detail? to track it.
RSpec.describe Enliterator::Configuration do
  subject(:config) { described_class.new }

  # Helper: stub Rails.env to a given environment name as a StringInquirer, so
  # `.development?` / `.production?` resolve the way the resolver reads them.
  def stub_rails_env(name)
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(name))
  end

  describe "#error_detail (default state)" do
    it "defaults to nil (auto)" do
      expect(config.error_detail).to be_nil
    end
  end

  describe "#error_detail? when error_detail is nil (auto)" do
    it "is true when Rails.env is development" do
      stub_rails_env("development")
      expect(config.error_detail?).to be(true)
    end

    it "is false when Rails.env is production" do
      stub_rails_env("production")
      expect(config.error_detail?).to be(false)
    end

    it "reads the env live (tracks a flip between calls, no memoization)" do
      stub_rails_env("production")
      expect(config.error_detail?).to be(false)
      stub_rails_env("development")
      expect(config.error_detail?).to be(true)
    end
  end

  describe "#error_detail? when forced on (true)" do
    it "is true even when Rails.env is production" do
      config.error_detail = true
      stub_rails_env("production")
      expect(config.error_detail?).to be(true)
    end
  end

  describe "#error_detail? when forced off (false)" do
    it "is false even when Rails.env is development" do
      config.error_detail = false
      stub_rails_env("development")
      expect(config.error_detail?).to be(false)
    end
  end

  describe "#error_detail_auto (host override)" do
    it "uses a host-supplied predicate when error_detail is nil" do
      config.error_detail_auto = -> { true }
      # No env stub: the override must decide, independent of Rails.env.
      expect(config.error_detail?).to be(true)
    end

    it "a host predicate of -> { false } forces off in auto state" do
      config.error_detail_auto = -> { false }
      stub_rails_env("development")
      expect(config.error_detail?).to be(false)
    end

    it "is ignored once error_detail is explicitly set (explicit beats auto)" do
      config.error_detail_auto = -> { true }
      config.error_detail = false
      expect(config.error_detail?).to be(false)
    end
  end

  describe "the defined?(Rails) guard on the default auto predicate" do
    # The default auto lambda mirrors the file's logger guard:
    #   defined?(Rails) && Rails.respond_to?(:env) && Rails.env.development?
    # Short-circuit && means that if Rails were undefined OR did not respond to
    # :env, the predicate returns a falsey value rather than raising. A full
    # Rails-undefined test is impractical inside a booted Rails test suite, so we
    # assert the guard's other arm: when Rails does not respond to :env, the
    # resolver returns false without raising. (`verify_partial_doubles` is on, so
    # this only succeeds because Rails really does respond to :env — we stub the
    # predicate to report otherwise.)
    it "returns false (never raises) when Rails does not respond to :env" do
      allow(Rails).to receive(:respond_to?).with(:env).and_return(false)
      expect { config.error_detail? }.not_to raise_error
      expect(config.error_detail?).to be(false)
    end
  end
end
