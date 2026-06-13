# frozen_string_literal: true

require "rails_helper"
require "open3"

# v0.29 citations: the inline-chip + sources-rail logic is client-side vanilla
# JS, federation-gated, that wraps consulted-record labels in the answer and
# links them to their records. Its load-bearing SAFETY properties — URL
# construction (prefer the tool's entry path, else statusBase + /Type/id, always
# URL-encoded) and the text-node-only / never-inside-a-link discipline of the
# chip wrapper — are guarded by a Node test that lifts the REAL shipped functions
# from the view and drives them against a minimal DOM shim (the same lift pattern
# as md_golden). This wrapper runs that script inside the suite so the guard
# travels with it. Run directly for the per-case breakdown:
#   node spec/javascript/cite_logic.test.js
RSpec.describe "client-side citation logic (citeUrl / wrapFirstMatch) safety", type: :script do
  let(:engine_root) { File.expand_path(File.join(__dir__, "..", "..")) }
  let(:script_path) { File.join(engine_root, "spec", "javascript", "cite_logic.test.js") }

  it "constructs record URLs correctly and wraps chips only on text nodes (never inside links)" do
    skip "node not available on PATH" if which("node").nil?

    stdout, stderr, status = Open3.capture3("node", script_path, chdir: engine_root)

    unless status.success?
      raise "Citation logic test failed (exit #{status.exitstatus}).\n" \
            "Run `node spec/javascript/cite_logic.test.js` for details.\n\n" \
            "STDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    end

    expect(status).to be_success
    expect(stdout).to include("0 failed")
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
