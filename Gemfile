source "https://rubygems.org"

# Specify your gem's dependencies in enliterator.gemspec.
gemspec

gem "puma"
gem "pg"
gem "propshaft"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

group :development, :test do
  gem "rspec-rails"
  gem "debug", ">= 1.0.0"
  # Provider gem for exercising the real Gateway/OpenAI adapters in dev (live
  # smoke tests). The engine itself does not depend on it — adapters lazy-require
  # it and hosts supply it. Specs use injected fakes and don't need it.
  gem "openai"
end

# Provider gems are host-supplied in real apps (lazy-required by adapters).
# They are NOT needed for the test suite, which uses the Null/Stub adapters.
# To exercise the real Bedrock/OpenAI adapters locally, uncomment:
# gem "aws-sdk-bedrockruntime"
# gem "openai"
