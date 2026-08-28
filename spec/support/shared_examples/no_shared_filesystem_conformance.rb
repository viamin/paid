# frozen_string_literal: true

# Conformance suite proving a runner satisfies RDR-057's no-shared-filesystem
# execution model. The suite drives the complete normal create-PR lifecycle —
# clone, run, log capture, artifact output, result manifest, cleanup — through
# the provider-neutral ExecutionRunners contract only:
#
# It fails when a runner requires shared host storage for normal create-PR
# execution: provisioning the host-path-free scenario must succeed, the runner
# must stream logs through +#start+, and any host path leaking into the
# persisted handle breaks the assertions below.
#
# Expected `let` bindings:
#
#   runner          — an instance of the concrete runner class, with its
#                     execution platform stubbed so provision/start/status/
#                     cleanup succeed and #start returns stdout output
#   conformance_run — a persisted AgentRun describing a normal create-PR
#                     execution: goal "create_pr", branch_name and
#                     base_commit_sha set, no worktree_path, and a
#                     verification_result carrying a durable artifact URL
#                     (the post-execution state the output manifest derives
#                     from)
#   conformance_expected_running — post-exit running? value reported by the
#                     stubbed platform (default: false)
#
# The suite derives the RunSpec itself via RunSpec.from_agent_run so every
# runner conforms to the same canonical, host-path-free scenario.
#
# @spec CONTAINER-RUNTIME-019
RSpec.shared_examples "a no-shared-filesystem runner" do
  let(:conformance_networking_policy) { ExecutionRunners::NetworkingPolicy.proxy_restricted }
  let(:conformance_expected_running) { false }
  let(:conformance_timestamps) do
    {
      provision_requested_at: Time.utc(2026, 8, 28, 12, 0, 0),
      environment_ready_at: Time.utc(2026, 8, 28, 12, 0, 1),
      first_output_at: Time.utc(2026, 8, 28, 12, 0, 2),
      workload_started_at: Time.utc(2026, 8, 28, 12, 0, 1),
      workload_finished_at: Time.utc(2026, 8, 28, 12, 0, 4),
      cleanup_requested_at: Time.utc(2026, 8, 28, 12, 0, 4),
      cleanup_finished_at: Time.utc(2026, 8, 28, 12, 0, 5)
    }
  end
  let(:conformance_spec) do
    ExecutionRunners::RunSpec.from_agent_run(
      conformance_run, networking_policy: conformance_networking_policy
    )
  end
  let(:conformance_command) { "paid-conformance-agent" }
  let(:conformance_dimension_results) do
    ExecutionRunners::ConformanceSuite::BenchmarkReport.default_dimension_results(
      passed: ExecutionRunners::ConformanceSuite.dimension_catalog.map { |entry| entry.fetch("key") },
      evidence: {
        "clone_fixture_repository" => conformance_spec.input_manifest.lanes.fetch("git").first.fetch("kind"),
        "run_workload" => "runner.start streamed fixture output",
        "clean_up_resources" => "runner.cleanup accepted repeated calls"
      }
    )
  end

  describe "lifecycle without host path assumptions" do
    it "provisions, runs, captures output, manifests results, and cleans up" do
      handle = runner.provision(spec: conformance_spec)
      expect(handle).to be_a(ExecutionRunners::RunnerHandle)

      result = runner.start(handle: handle, command: conformance_command, timeout: 60,
        startup_timeout: 30, idle_timeout: 30, abort_patterns: nil, preparation: nil,
        heartbeat_path: nil)

      expect(result).to be_success
      expect(result.stdout).to be_present

      expect(runner.running?(handle: handle)).to be(conformance_expected_running)
      expect(runner.status(handle: handle)).to be_a(ExecutionRunners::ExecutionStatus)

      # Cleanup is idempotent: a second call for a torn-down handle is a no-op.
      expect {
        runner.cleanup(handle: handle, force: true)
        runner.cleanup(handle: handle, force: true)
      }.not_to raise_error
    end

    # @spec CONTAINER-RUNTIME-045
    it "emits a comparable benchmark report for the canonical fixture workload" do
      handle = runner.provision(spec: conformance_spec)
      result = runner.start(handle: handle, command: conformance_command, timeout: 60,
        startup_timeout: 30, idle_timeout: 30, abort_patterns: nil, preparation: nil,
        heartbeat_path: nil)
      runner.cleanup(handle: handle, force: true)

      report = conformance_benchmark_report(result:)

      expect(report.as_json.fetch("fixture")).to include(
        "name" => "runner-conformance-fixture",
        "entrypoint" => "bin/conformance-task",
        "expected_stdout" => "CONFORMANCE_OK"
      )
      expect(report.as_json.fetch("benchmark")).to include(
        "provisioning_latency_ms" => 1000,
        "cold_start_latency_ms" => 2000,
        "execution_duration_ms" => 3000,
        "cleanup_latency_ms" => 1000
      )
      expect(report.as_json.fetch("dimensions").size).to eq(13)
    end

    it "yields at least one streamed chunk through the start block" do
      handle = runner.provision(spec: conformance_spec)

      streamed = []
      runner.start(handle: handle, command: conformance_command, timeout: 60,
        startup_timeout: 30, idle_timeout: 30, abort_patterns: nil, preparation: nil,
        heartbeat_path: nil) { |stream, chunk| streamed << [ stream, chunk ] }

      # The runner must yield at least one chunk; an empty stream would mean
      # the runner is buffering (or worse, dropping) output that should travel
      # on the control-plane API lane, not through shared host storage.
      expect(streamed).not_to be_empty
      expect(streamed).to all(satisfy { |stream, chunk| %i[stdout stderr].include?(stream) && chunk.is_a?(String) })
    end

    it "keeps host filesystem paths out of the persisted handle" do
      handle = runner.provision(spec: conformance_spec)

      expect(handle.workspace_ref).not_to match(NoSharedFilesystemConformance::HOST_PATH_PATTERN)
      expect(NoSharedFilesystemConformance.host_path_strings(handle.as_json)).to be_empty
    end
  end

  def conformance_benchmark_report(result:)
    ExecutionRunners::ConformanceSuite::BenchmarkReport.build(
      runner_type: runner.class.name.demodulize.underscore,
      runner_backend: conformance_run.container_host || "unknown",
      timestamps: conformance_timestamps,
      execution_result: result,
      agent_run: conformance_run,
      dimension_results: conformance_dimension_results
    )
  end
end
