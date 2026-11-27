# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"

# Cold-worker replay coverage for the evolution workflows. The in-process
# replay coverage in `spec/temporal/workflow_replay_fixtures_spec.rb` runs
# after `Rails.application.eager_load!`, so it cannot surface failures that
# only occur when a fresh worker process lazily resolves autoload-managed
# constants from the workflow thread. This spec boots a separate cold worker
# process (no eager loading, `bin/temporal_worker` file-require order) and
# asserts it replays the checked-in evolution histories cleanly.
RSpec.describe WorkflowReplayFixtures, :no_db do
  def run_cold_worker_replay
    # CI presence makes config/environments/test.rb eager-load the app, which
    # would silently turn the cold worker into a warm one.
    Open3.capture3(
      { "CI" => nil, "RAILS_ENV" => "test" },
      "bundle", "exec", "ruby", "script/temporal/replay_cold_worker.rb",
      chdir: Rails.root.to_s
    )
  end

  # @spec TEMPORAL-ORCHESTRATION-023, PROMPT-EVOLUTION-006
  it "replays every evolution history from a cold worker without lazy-load nondeterminism" do
    stdout, stderr, status = run_cold_worker_replay

    expect(status.success?).to be(true), -> { "stderr: #{stderr}" }
    report = JSON.parse(stdout)

    expect(report.fetch("cold").values).to all(be true)
    expect(report.fetch("replays").values).to all(be_nil)
  end
end
