# This file boots the dummy host app at spec/dummy and configures RSpec for
# Rails-aware specs. Required by every spec that touches the engine's models,
# jobs, or the dummy Widget host model.
require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

# Boot the dummy application (spec/dummy) — it mounts the engine and provides
# the Widget host model that includes Enliterator::Tendable.
require_relative "dummy/config/environment"

# Prevent destructive migration loss from running specs against a non-test DB.
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"

# Pending engine migrations (written in a later phase) will raise here once they
# exist; this surfaces a clear "run db:migrate" message instead of opaque errors.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # Reset Enliterator to defaults before the suite so the Null adapters are the
  # baseline in tests (no network, deterministic). Individual specs may override
  # configuration.llm_adapter / embedder_adapter inside their own examples.
  config.before(:suite) do
    Enliterator.reset_configuration!
  end

  # Each example gets a fresh, default configuration so stubs from one spec do
  # not leak into the next.
  config.before(:each) do
    Enliterator.reset_configuration!
    # v0.17: condition probes are module state like the configuration — a probe
    # registered in one example must not survey for the next.
    Enliterator::Condition.reset_registry!
    # v0.5: the suite legitimately runs the inert Null adapter (deterministic, no
    # network). Opt in suite-wide so the production-only "refuse Null" guard stays
    # inert in tests. reset_configuration! restores the false default each example,
    # so a spec exercising the guard can flip it back off explicitly.
    Enliterator.configuration.allow_null_llm = true
  end

  # Use transactional fixtures: each example runs inside a transaction that is
  # rolled back at the end, keeping specs fast and isolated.
  config.use_transactional_fixtures = true

  # Infer spec type (model/job/request/...) from the spec's directory.
  config.infer_spec_type_from_file_location!

  # Trim Rails framework lines from backtraces.
  config.filter_rails_from_backtrace!
end
