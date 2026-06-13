# frozen_string_literal: true

require "rails_helper"
require "open3"

# The conversation view's markdown renderer (esc / inline / mdToHtml) is
# client-side vanilla JS shared by BOTH the agentic-federation path and the
# single-shot path. Extending it (v0.29: blockquotes, rules, tables, nested
# lists) is the highest-regression-risk change in the chat UI, so it is guarded
# by a Node golden-output test that freezes the prior rendering surface.
#
# This spec runs that Node script inside `bundle exec rspec` so the guard travels
# with the suite. The actual assertions (byte-identity of pre-existing cases,
# presence of the new elements, negative guards) live in md_golden.test.js;
# this wrapper surfaces a non-zero exit as a single RSpec failure with the full
# Node output attached. Run the script directly for the per-case breakdown:
#   node spec/javascript/md_golden.test.js
RSpec.describe "client-side markdown renderer (mdToHtml) golden output", type: :script do
  # Rails.root is spec/dummy; the engine root is two levels up from this file.
  let(:engine_root) { File.expand_path(File.join(__dir__, "..", "..")) }
  let(:script_path) { File.join(engine_root, "spec", "javascript", "md_golden.test.js") }

  it "renders every pre-existing markdown shape byte-identically and supports the new syntax" do
    skip "node not available on PATH" if which("node").nil?

    # Never let the suite silently re-baseline the golden file.
    env = { "UPDATE_GOLDEN" => nil }
    stdout, stderr, status = Open3.capture3(env, "node", script_path, chdir: engine_root)

    unless status.success?
      raise "Golden markdown test failed (exit #{status.exitstatus}).\n" \
            "Run `node spec/javascript/md_golden.test.js` for details.\n\n" \
            "STDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    end

    expect(status).to be_success
    expect(stdout).to include("All golden + new-syntax + negative cases passed.")
  end

  # Tiny PATH probe so the spec degrades to a skip (not an error) where node is absent.
  def which(cmd)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      exe = File.join(dir, cmd)
      return exe if File.executable?(exe) && !File.directory?(exe)
    end
    nil
  end
end
