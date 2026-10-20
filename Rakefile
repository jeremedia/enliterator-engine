require "bundler/setup"

APP_RAKEFILE = File.expand_path("spec/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "bundler/gem_tasks"
require_relative "lib/enliterator/release_check"

# The release is Enliterator::VERSION (option A, hub ledger 1e2df0). `rake release`
# tags "v#{VERSION}" and pushes it; this guard runs before the tag is cut.
desc "Refuse a release unless lib/enliterator/version.rb names a new one"
task "release:version_check" do
  tags = `git tag --list "v*"`.split
  abort "release:version_check: could not list git tags" unless $?.success?

  problems = Enliterator::ReleaseCheck.problems(version: Enliterator::VERSION, tags: tags)
  abort problems.map { |p| "release:version_check: #{p}" }.join("\n") if problems.any?
  puts "release:version_check: v#{Enliterator::VERSION} is a new release"
end
Rake::Task["release:source_control_push"].enhance([ "release:version_check" ])

# The engine ships to hosts as a git tag, never to RubyGems.
Rake::Task["release"].clear_comments
Rake::Task["release"].add_description "Check VERSION is a new release, tag v#{Enliterator::VERSION}, push the branch and tag (no RubyGems push)"
Rake::Task["release:rubygem_push"].clear
task "release:rubygem_push" do
  puts "release:rubygem_push: skipped (the engine ships as a git tag, not a RubyGems gem)"
end
