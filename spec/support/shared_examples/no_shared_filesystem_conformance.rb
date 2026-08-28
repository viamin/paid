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
  let(:conformance_command) { "paid-conformance-agent" }
  let(:conformance_passed_dimensions) do
    %w[
      provision_execution
      clone_fixture_repository
      run_workload
      retrieve_and_stream_logs
      report_success_or_failure
      clean_up_resources
    ]
  end
  let(:conformance_report_fixture) do
    {
      "name" => "runner-contract-baseline",
      "entrypoint" => conformance_command,
      "requires_llm" => false,
      "description" => "Shared-example baseline workload. Override this metadata when the suite actually runs the repository fixture."
    }
  end
  let(:conformance_spec) do
    ExecutionRunners::RunSpec.from_agent_run(
      conformance_run, networking_policy: conformance_networking_policy
    )
  end
  let(:conformance_dimension_results) do
    ExecutionRunners::ConformanceSuite::BenchmarkReport.default_dimension_results(
      passed: conformance_passed_dimensions,
      evidence: {
        "provision_execution" => "runner.provision returned a RunnerHandle",
        "clone_fixture_repository" => "input_manifest declares a repository_checkout Git lane",
        "run_workload" => "runner.start executed #{conformance_command}",
        "retrieve_and_stream_logs" => "runner.start yielded streamed stdout/stderr chunks",
        "report_success_or_failure" => "ExecutionResult captured terminal exit state",
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
    it "emits a comparable benchmark report for the workload it exercised" do
      run = measured_conformance_run
      checkout_lane = conformance_spec.input_manifest.lanes.fetch("git")

      report = conformance_benchmark_report(result: run.fetch(:result), timestamps: run.fetch(:timestamps))

      expect_checkout_lane(checkout_lane)
      expect_report_fixture(report)
      expect_report_benchmarks(report)
      expect_report_dimensions(report)
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

  def conformance_benchmark_report(result:, timestamps:)
    ExecutionRunners::ConformanceSuite::BenchmarkReport.build(
      runner_type: runner.class.name.demodulize.underscore,
      runner_backend: conformance_run.container_host || "unknown",
      timestamps: timestamps,
      execution_result: result,
      agent_run: conformance_run,
      dimension_results: conformance_dimension_results,
      fixture: conformance_report_fixture
    )
  end

  def measured_conformance_run
    timestamps = { provision_requested_at: Time.now.utc }
    handle = runner.provision(spec: conformance_spec)
    timestamps[:environment_ready_at] = Time.now.utc
    timestamps[:workload_started_at] = Time.now.utc

    first_output_at = nil
    result = runner.start(handle: handle, command: conformance_command, timeout: 60,
      startup_timeout: 30, idle_timeout: 30, abort_patterns: nil, preparation: nil,
      heartbeat_path: nil) do |stream, chunk|
        first_output_at ||= Time.now.utc
        yield stream, chunk if block_given?
      end

    timestamps[:first_output_at] = first_output_at || timestamps.fetch(:workload_started_at)
    timestamps[:workload_finished_at] = Time.now.utc
    timestamps[:cleanup_requested_at] = Time.now.utc
    runner.cleanup(handle: handle, force: true)
    timestamps[:cleanup_finished_at] = Time.now.utc

    {
      handle: handle,
      result: result,
      timestamps: timestamps
    }
  end

  def expect_checkout_lane(checkout_lane)
    expect(checkout_lane).to include(hash_including("kind" => "repository_checkout"))
  end

  def expect_report_fixture(report)
    expect(report.as_json.fetch("fixture")).to include(
      "name" => "runner-contract-baseline",
      "entrypoint" => conformance_command
    )
  end

  def expect_report_benchmarks(report)
    expect(report.as_json.fetch("benchmark")).to include(
      "provisioning_latency_ms" => be >= 0,
      "cold_start_latency_ms" => be >= 0,
      "execution_duration_ms" => be >= 0,
      "cleanup_latency_ms" => be >= 0
    )
  end

  def expect_report_dimensions(report)
    expect(report.as_json.fetch("dimensions")).to include(
      hash_including("key" => "run_workload", "status" => "pass"),
      hash_including("key" => "handle_non_zero_exits", "status" => "not_exercised"),
      hash_including("key" => "enforce_timeout", "status" => "not_exercised"),
      hash_including("key" => "cancel_running_workload", "status" => "not_exercised"),
      hash_including("key" => "demonstrate_retry_and_idempotency", "status" => "not_exercised")
    )
    expect(report.as_json.fetch("dimensions").size).to eq(13)
  end
end
