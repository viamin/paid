# frozen_string_literal: true

require "shellwords"
require "open3"

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
  let(:conformance_report_fixture) { ExecutionRunners::ConformanceSuite.fixture_workload }
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
        "clone_fixture_repository" => "runner.start ran a real `git clone` of the fixture repo into an isolated dir",
        "run_workload" => "runner.start executed the cloned fixture entrypoint and produced its expected stdout token",
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
    it "emits a comparable benchmark report for the workload it actually cloned and ran" do
      fixture = ExecutionRunners::ConformanceSuite.fixture_workload
      destination = conformance_fixture_checkout_destination

      # Nothing pre-populates `destination`: the command below must clone the
      # fixture into it for real, through the runner's own #start, before the
      # entrypoint or artifact can exist here. A runner that never performs
      # the clone has nothing to execute and this test fails closed.
      benchmark = conformance_benchmark_run(command: fixture_clone_and_run_command(destination, fixture))
      checkout_lane = conformance_spec.input_manifest.lanes.fetch("git")

      expect(destination.join(fixture.fetch("entrypoint"))).to exist
      expect(benchmark.execution_result.stdout).to include(fixture.fetch("expected_stdout"))
      expect(destination.join(fixture.fetch("expected_artifact_path"))).to exist

      expect_checkout_lane(checkout_lane)
      expect_report_fixture(benchmark.report)
      expect_report_benchmarks(benchmark.report)
      expect_report_dimensions(benchmark.report)
    ensure
      FileUtils.remove_entry(destination.dirname) if destination
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

  # A throwaway git repository built from the fixture tree, used only as a
  # clone *source*. The checkout the assertions inspect is never built here:
  # it comes from the runner-executed `git clone` in
  # +fixture_clone_and_run_command+.
  def conformance_fixture_git_source
    @conformance_fixture_git_source ||= begin
      source = Pathname(Dir.mktmpdir("conformance-fixture-source"))
      fixture_root = Rails.root.join(ExecutionRunners::ConformanceSuite::FIXTURE_REPO_RELATIVE_PATH)
      FileUtils.cp_r("#{fixture_root}/.", source)
      run_git!(source, "init", "--quiet")
      run_git!(source, "add", "-A")
      run_git!(source, "-c", "user.email=conformance@paid.test", "-c", "user.name=Conformance",
        "commit", "--quiet", "-m", "conformance fixture")
      source
    end
  end

  def run_git!(dir, *args)
    _stdout, status = Open3.capture2("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed in #{dir}" unless status.success?
  end

  # A path that does not exist yet: nothing outside the runner populates it,
  # so the workload command must `git clone` into it for real.
  def conformance_fixture_checkout_destination
    Pathname(Dir.mktmpdir("conformance-fixture-checkout")).join("repo")
  end

  def fixture_clone_and_run_command(destination, fixture)
    clone = "git clone --quiet #{Shellwords.escape(conformance_fixture_git_source.to_s)} " \
      "#{Shellwords.escape(destination.to_s)}"
    "#{clone} && cd #{Shellwords.escape(destination.to_s)} && #{fixture.fetch('entrypoint')}"
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
