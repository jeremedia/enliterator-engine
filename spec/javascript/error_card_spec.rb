# frozen_string_literal: true

require "rails_helper"
require "open3"

# v0.30 actionable error card: when the server emits a structured :error SSE
# payload, the chat client renders it as a distinct, readable card. Its
# load-bearing SAFETY property — EVERY payload value (message/detail/where/hint)
# is written via textContent, never innerHTML, so an injected <img onerror>/
# <script> is inert text — is guarded by a Node test that lifts the REAL shipped
# renderErrorCard from the view and drives it against a minimal DOM shim (the
# same lift pattern as cite_logic / md_golden). This wrapper runs that script
# inside the suite so the guard travels with it. Run directly for the per-case
# breakdown:
#   node spec/javascript/error_card.test.js
RSpec.describe "client-side error card (renderErrorCard) safety", type: :script do
  let(:engine_root) { File.expand_path(File.join(__dir__, "..", "..")) }
  let(:script_path) { File.join(engine_root, "spec", "javascript", "error_card.test.js") }

  it "renders message-only vs full payloads correctly and keeps injected markup inert (textContent)" do
    skip "node not available on PATH" if which("node").nil?

    stdout, stderr, status = Open3.capture3("node", script_path, chdir: engine_root)

    unless status.success?
      raise "Error card test failed (exit #{status.exitstatus}).\n" \
            "Run `node spec/javascript/error_card.test.js` for details.\n\n" \
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
