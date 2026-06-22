# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "atlas renderer client smoke", type: :script do
  let(:engine_root) { File.expand_path(File.join(__dir__, "..", "..")) }
  let(:script_path) { File.join(engine_root, "spec", "javascript", "atlas_renderer_smoke.test.js") }

  it "builds the graph model, searches, switches modes, and populates inspector HTML" do
    skip "node not available on PATH" if which("node").nil?

    stdout, stderr, status = Open3.capture3("node", script_path, chdir: engine_root)

    unless status.success?
      raise "Atlas renderer smoke test failed (exit #{status.exitstatus}).\n" \
            "Run `node spec/javascript/atlas_renderer_smoke.test.js` for details.\n\n" \
            "STDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    end

    expect(stdout).to include("0 failed")
  end

  def which(cmd)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      exe = File.join(dir, cmd)
      return exe if File.executable?(exe) && !File.directory?(exe)
    end
    nil
  end
end
