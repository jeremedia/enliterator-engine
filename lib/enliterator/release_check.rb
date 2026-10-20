# frozen_string_literal: true

module Enliterator
  # The release guard behind `rake release` (engine Rakefile only; hosts never load
  # this file). Enliterator::VERSION is the single source of the release, so a
  # release may only be cut once VERSION names a new one. Bundler's own
  # `release:source_control_push` SKIPS tagging when the tag already exists and
  # pushes anyway — an unbumped VERSION would ship a commit no tag names, which is
  # how every tag through v0.90.1 came to carry "0.1.0". This refuses that instead.
  module ReleaseCheck
    TAG_RX = /\Av(\d+(?:\.\d+)*)\z/

    module_function

    # Problems with cutting a release of +version+ given the repo's +tags+.
    # Empty means the release may be cut.
    def problems(version:, tags:)
      unless Gem::Version.correct?(version)
        return [ "VERSION #{version.inspect} is not a valid version (lib/enliterator/version.rb)" ]
      end

      current  = Gem::Version.new(version)
      released = tags.filter_map { |t| t[TAG_RX, 1] }.map { |v| Gem::Version.new(v) }
      latest   = released.max

      if released.include?(current)
        [ "v#{version} is already tagged; bump VERSION in lib/enliterator/version.rb to the release being cut" ]
      elsif latest && current < latest
        [ "VERSION #{version} is behind the latest release tag v#{latest}; bump it to the release being cut" ]
      else
        []
      end
    end
  end
end
