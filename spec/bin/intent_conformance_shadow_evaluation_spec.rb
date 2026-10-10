# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# @spec INTENT-CONFORMANCE-ROLLOUT-002
# @spec INTENT-CONFORMANCE-ROLLOUT-003
RSpec.describe "bin/intent-conformance-shadow-evaluation" do # rubocop:disable RSpec/DescribeClass
  let(:script_path) { File.expand_path("../../bin/intent-conformance-shadow-evaluation", __dir__) }
  let(:commit) { "a" * 40 }

  # The CLI runs as a plain `ruby` subprocess with no Rails/ActiveSupport loaded
  # (see bin/intent-conformance-shadow-evaluation), unlike the lib specs which run
  # under rails_helper. This is the only coverage that exercises that constraint.
  it "compiles a worksheet from a complete ledger without relying on ActiveSupport core extensions" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)
      File.write(ledger, complete_ledger_events.map { |event| JSON.generate(event) }.join("\n"))

      stdout, stderr, status = run_cli("compile", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", commit)

      expect(status.exitstatus).to eq(0), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("| Review cost | 100 cents | shadow_run |")
    end
  end

  def complete_ledger_events
    base = { "manifest_commit" => commit }
    [
      base.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[op-a op-b], "recorded_at" => "2026-10-10T08:00:00Z"),
      base.merge("type" => "adjudication", "event_id" => "a01-1", "case_id" => "A-01", "operator" => "op-a", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z"),
      base.merge("type" => "adjudication", "event_id" => "a01-2", "case_id" => "A-01", "operator" => "op-b", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:02:00Z"),
      base.merge("type" => "shadow_run", "event_id" => "run-a01", "case_id" => "A-01", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 100, "recorded_at" => "2026-10-10T09:00:00Z")
    ]
  end

  def run_cli(*args)
    Open3.capture3("ruby", script_path, *args)
  end
end
