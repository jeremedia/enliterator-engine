# frozen_string_literal: true

require "rails_helper"
require "enliterator/release_check"

# The release is Enliterator::VERSION (hub ledger 1e2df0, option A): the gemspec
# reads it and `rake release` refuses to tag unless it names a new release.
RSpec.describe Enliterator::ReleaseCheck do
  let(:tags) { %w[v0.89 v0.90 v0.90.1 not-a-release v0.9] }

  it "passes a VERSION newer than every release tag" do
    expect(described_class.problems(version: "0.91.0", tags: tags)).to eq([])
  end

  it "refuses a VERSION that is already tagged (the unbumped release)" do
    expect(described_class.problems(version: "0.90.1", tags: tags).first).to include("already tagged")
  end

  it "refuses a VERSION behind the latest release tag" do
    expect(described_class.problems(version: "0.1.0", tags: tags).first).to include("behind the latest release tag v0.90.1")
  end

  it "compares versions numerically, not as strings" do
    expect(described_class.problems(version: "0.10.0", tags: %w[v0.9])).to eq([])
  end

  it "ignores tags that do not name a release" do
    expect(described_class.problems(version: "0.1.0", tags: %w[not-a-release vnext])).to eq([])
  end

  it "refuses an invalid VERSION" do
    expect(described_class.problems(version: "next", tags: tags).first).to include("not a valid version")
  end

  it "is the version the gemspec ships" do
    spec = Gem::Specification.load(File.expand_path("../../../enliterator.gemspec", __dir__))
    expect(spec.version.to_s).to eq(Enliterator::VERSION)
  end
end
