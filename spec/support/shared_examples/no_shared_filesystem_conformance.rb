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
#                     cleanup succeed and #start returns stdout output. A
#                     stubbed platform must answer a fixture workload command
#                     (NoSharedFilesystemConformance.fixture_workload_command?)
#                     with NoSharedFilesystemConformance.fixture_workload_stdout
#                     — the output the workload produces inside the
#                     environment. The stub stays at the runner seam: running
#                     the workload on the host instead would assert nothing
#                     about the runner boundary
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
  let(:conformance_report_fixture) { ExecutionRunners::ConformanceSuite.fixture_workload }
  # Clone source and checkout path for the fixture workload. Both are
  # declarative locations the *environment* resolves: the runner clones the
  # source into the checkout path inside its own environment, and nothing
  # outside the runner writes or reads either one. A runner exercised against a
  # real (unstubbed) platform overrides the source with a location that
  # platform can reach.
  let(:conformance_fixture_clone_source) { "https://conformance.test/runner-conformance-fixture.git" }
  let(:conformance_fixture_checkout_path) { "/tmp/paid-conformance-checkout/repo" }
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
        "clone_fixture_repository" => "runner.start ran the fixture `git clone` inside the provisioned environment",
        "run_workload" => "the fixture entrypoint token and artifact returned over runner.start's own stream",
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
    it "emits a comparable benchmark report from the fixture workload it ran and streamed back" do
      fixture = ExecutionRunners::ConformanceSuite.fixture_workload
      benchmark = conformance_benchmark_run(command: conformance_fixture_workload_command)
      stdout = benchmark.execution_result.stdout

      expect(benchmark.execution_result).to be_success
      expect(benchmark.report.as_json.fetch("result")).to include("success" => true)

      # Every piece of workload evidence returns over the runner's own stdout:
      # the entrypoint token, then the artifact the entrypoint wrote, read back
      # on the same stream. Host filesystem state is deliberately not inspected
      # — a runner executing inside its own environment never populates it, so
      # a host-side assertion would only prove the test harness ran.
      expect(stdout).to include(fixture.fetch("expected_stdout"))
      expect(NoSharedFilesystemConformance.reported_fixture_artifact(stdout))
        .to include("token" => fixture.fetch("expected_stdout"))

      expect_checkout_lane(conformance_spec.input_manifest.lanes.fetch("git"))
      expect_report_fixture(benchmark.report)
      expect_report_benchmarks(benchmark.report)
      expect_report_dimensions(benchmark.report)
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

  # Delegates to the runner-owned benchmark harness (production code, not
  # test scaffolding) so a regression in report generation fails this suite
  # instead of silently disappearing into test-only bookkeeping.
  def conformance_benchmark_run(command:)
    ExecutionRunners::ConformanceSuite::Benchmark.run(
      runner: runner,
      spec: conformance_spec,
      command: command,
      dimension_results: conformance_dimension_results,
      fixture: conformance_report_fixture
    )
  end

  def conformance_fixture_workload_command
    NoSharedFilesystemConformance.fixture_workload_command(
      source: conformance_fixture_clone_source,
      destination: conformance_fixture_checkout_path,
      fixture: conformance_report_fixture
    )
  end

  def expect_checkout_lane(checkout_lane)
    expect(checkout_lane).to include(hash_including("kind" => "repository_checkout"))
  end

  def expect_report_fixture(report)
    expect(report.as_json.fetch("fixture")).to eq(conformance_report_fixture)
  end

  def expect_report_benchmarks(report)
    expect(report.as_json.fetch("benchmark")).to include(
      "provisioning_latency_ms" => be >= 0,
      "cold_start_latency_ms" => be >= 0,
      "execution_duration_ms" => be >= 0,
      "cleanup_latency_ms" => be >= 0
    )
  end

  # Pins every dimension's status explicitly (not just the ones this baseline
  # exercises) so a future runner that starts covering, e.g.,
  # `inject_configuration` shows up here as an intentional change to this
  # list rather than silently passing through `include`. This baseline only
  # exercises `conformance_passed_dimensions`; the rest stay `not_exercised`
  # until the shared runner contract work (#3347) covers them for a given
  # runner.
  def expect_report_dimensions(report)
    dimensions = report.as_json.fetch("dimensions")
    expect(dimensions.size).to eq(13)

    expected_statuses = ExecutionRunners::ConformanceSuite.dimension_catalog.to_h do |dimension|
      key = dimension.fetch("key")
      [ key, conformance_passed_dimensions.include?(key) ? "pass" : "not_exercised" ]
    end

    actual_statuses = dimensions.to_h { |dimension| [ dimension.fetch("key"), dimension.fetch("status") ] }
    expect(actual_statuses).to eq(expected_statuses)
  end
end
