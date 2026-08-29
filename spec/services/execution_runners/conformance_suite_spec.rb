# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-045
RSpec.describe ExecutionRunners::ConformanceSuite do
  describe ".fixture_workload" do
    it "describes the deterministic fixture repository used by the shared suite" do
      workload = described_class.fixture_workload

      expect(workload).to include(
        "name" => "runner-conformance-fixture",
        "entrypoint" => "bin/conformance-task",
        "expected_stdout" => "CONFORMANCE_OK",
        "expected_artifact_path" => "artifacts/conformance-result.json",
        "requires_llm" => false
      )
      expect(Rails.root.join(workload.fetch("relative_repo_path"))).to exist
    end
  end

  describe ".dimension_catalog" do
    it "defines the 13 production-readiness dimensions for #3347 coverage" do
      expect(described_class.dimension_catalog.map { |entry| entry.fetch("key") }).to eq(
        %w[
          provision_execution
          clone_fixture_repository
          inject_configuration
          provide_secrets_securely
          run_workload
          provision_service_dependencies
          retrieve_and_stream_logs
          report_success_or_failure
          handle_non_zero_exits
          enforce_timeout
          cancel_running_workload
          clean_up_resources
          demonstrate_retry_and_idempotency
        ]
      )
    end
  end

  describe ExecutionRunners::ConformanceSuite::BenchmarkReport do
    let(:generated_at) { Time.utc(2026, 8, 28, 12, 0, 5) }
    let(:agent_run) do
      create(
        :agent_run,
        peak_cpu_percent: 55.5,
        peak_memory_bytes: 134_217_728,
        container_metrics_count: 4,
        infra_cost_cents: 17,
        billed_duration_seconds: 45
      )
    end
    let(:timestamps) do
      {
        provision_requested_at: Time.utc(2026, 8, 28, 12, 0, 0),
        environment_ready_at: Time.utc(2026, 8, 28, 12, 0, 1),
        first_output_at: Time.utc(2026, 8, 28, 12, 0, 2),
        workload_started_at: Time.utc(2026, 8, 28, 12, 0, 1),
        workload_finished_at: Time.utc(2026, 8, 28, 12, 0, 4),
        cleanup_requested_at: Time.utc(2026, 8, 28, 12, 0, 4),
        cleanup_finished_at: generated_at
      }
    end
    let(:dimension_results) do
      described_class.default_dimension_results(
        passed: %w[
          provision_execution
          clone_fixture_repository
          inject_configuration
          provide_secrets_securely
          run_workload
          provision_service_dependencies
          retrieve_and_stream_logs
          report_success_or_failure
          clean_up_resources
        ],
        evidence: {
          "run_workload" => "fixture wrote artifacts/conformance-result.json"
        }
      )
    end
    let(:execution_result) do
      ExecutionRunners::ExecutionResult.success(stdout: "CONFORMANCE_OK\n")
    end

    it "serializes a JSON-ready benchmark report with lifecycle metrics" do
      report = build_report(execution_result:, dimension_results:)

      expect_report_header(report)
      expect_benchmark_metrics(report)
      expect_resource_usage(report)
      expect_cost(report)
      expect_dimensions(report)
      expect(report.as_json.fetch("result")).to include("success" => true, "exit_code" => 0)
    end

    it "rejects reports missing one of the required dimensions" do
      incomplete = dimension_results.reject { |entry| entry.fetch("key") == "cancel_running_workload" }

      expect do
        build_report(
          execution_result: ExecutionRunners::ExecutionResult.success(stdout: "ok"),
          dimension_results: incomplete
        )
      end.to raise_error(ArgumentError, /Missing conformance dimensions: cancel_running_workload/)
    end

    it "rejects default dimension results with unknown passed keys" do
      expect do
        described_class.default_dimension_results(
          passed: %w[run_worklaod],
          evidence: {}
        )
      end.to raise_error(ArgumentError, /Unknown conformance dimensions: run_worklaod/)
    end

    it "normalizes symbol keys before marking dimensions as passed or attaching evidence" do
      results = described_class.default_dimension_results(
        passed: [ :run_workload ],
        evidence: { run_workload: "fixture wrote artifacts/conformance-result.json" }
      )

      run_workload = results.find { |entry| entry.fetch("key") == "run_workload" }

      expect(run_workload).to include(
        "status" => "pass",
        "evidence" => "fixture wrote artifacts/conformance-result.json"
      )
    end

    it "rejects reports with duplicate dimensions" do
      duplicate = dimension_results + [ dimension_results.fetch(0) ]

      expect do
        build_report(
          execution_result: ExecutionRunners::ExecutionResult.success(stdout: "ok"),
          dimension_results: duplicate
        )
      end.to raise_error(ArgumentError, /Duplicate conformance dimensions: provision_execution/)
    end

    it "rejects reports with unknown dimensions" do
      extra = dimension_results + [
        {
          "key" => "unexpected_dimension",
          "label" => "Unexpected dimension",
          "status" => "pass",
          "activities" => [],
          "description" => "Unexpected"
        }
      ]

      expect do
        build_report(
          execution_result: ExecutionRunners::ExecutionResult.success(stdout: "ok"),
          dimension_results: extra
        )
      end.to raise_error(ArgumentError, /Unknown conformance dimensions: unexpected_dimension/)
    end

    def build_report(execution_result:, dimension_results:)
      described_class.build(
        runner_type: :local_docker,
        runner_backend: "local",
        timestamps: timestamps,
        execution_result: execution_result,
        agent_run: agent_run,
        dimension_results: dimension_results
      )
    end

    def expect_report_header(report)
      expect(report.to_h).to include(
        schema_version: "runner_conformance_benchmark.v1",
        generated_at: "2026-08-28T12:00:05Z"
      )
    end

    def expect_benchmark_metrics(report)
      expect(report.to_h.fetch(:benchmark)).to eq(
        "provisioning_latency_ms" => 1000,
        "cold_start_latency_ms" => 2000,
        "execution_duration_ms" => 3000,
        "cleanup_latency_ms" => 1000
      )
    end

    def expect_resource_usage(report)
      expect(report.to_h.fetch(:resource_usage)).to include(
        "peak_cpu_percent" => 55.5,
        "peak_memory_bytes" => 134_217_728,
        "peak_disk_bytes" => nil,
        "container_metric_samples" => 4
      )
    end

    def expect_cost(report)
      expect(report.to_h.fetch(:cost)).to include(
        "estimated_infra_cost_cents" => 17,
        "billed_duration_seconds" => 45
      )
    end

    def expect_dimensions(report)
      expect(report.to_h.fetch(:dimensions).size).to eq(13)
    end
  end

  # @spec CONTAINER-RUNTIME-045
  describe ExecutionRunners::ConformanceSuite::Benchmark do
    let(:agent_run) do
      create(
        :agent_run,
        goal: "create_pr",
        branch_name: "feature/conformance",
        base_commit_sha: "cafebabecafebabecafebabecafebabecafebabe",
        container_host: "local"
      )
    end
    let(:run_spec) do
      ExecutionRunners::RunSpec.from_agent_run(
        agent_run, networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
      )
    end
    let(:handle) { instance_double(ExecutionRunners::RunnerHandle, host: "provisioned-host") }
    let(:runner) { instance_double(ExecutionRunners::Base, provision: handle, cleanup: nil) }
    let(:dimension_results) do
      ExecutionRunners::ConformanceSuite::BenchmarkReport.default_dimension_results(
        passed: %w[provision_execution run_workload clean_up_resources]
      )
    end

    it "starts the workload with the timeout carried on the run's resources, not a shorter hardcoded limit" do
      allow(runner).to receive(:start).and_return(ExecutionRunners::ExecutionResult.success(stdout: "ok"))

      run_benchmark

      expect(runner).to have_received(:start).with(
        hash_including(
          timeout: run_spec.resources.timeout_seconds,
          startup_timeout: run_spec.resources.timeout_seconds,
          idle_timeout: run_spec.resources.timeout_seconds
        )
      )
    end

    it "reports cleanup latency from the runner's own teardown" do
      allow(runner).to receive(:start) do |**_, &block|
        block&.call(:stdout, "CONFORMANCE_OK\n")
        ExecutionRunners::ExecutionResult.success(stdout: "CONFORMANCE_OK\n")
      end

      result = run_benchmark

      expect(runner).to have_received(:cleanup).with(handle: handle, force: true)
      expect(result.report.as_json.fetch("benchmark")).to include("cleanup_latency_ms" => be >= 0)
      # runner_backend must reflect the provisioned handle, not the agent
      # run's pre-provision container_host (which stays "local" here while
      # the stubbed handle reports a different host).
      expect(result.report.as_json.fetch("runner")).to include("runner_backend" => "provisioned-host")
    end

    # @spec CONTAINER-RUNTIME-045
    it "cleans up and still emits a benchmark report when the workload raises a classified timeout" do
      allow(runner).to receive(:start).and_raise(ExecutionRunners::TimeoutError, "wall-clock timeout")

      result = run_benchmark

      expect(runner).to have_received(:cleanup).with(handle: handle, force: true)
      expect(result.execution_result).to be_failure
      expect(result.report.as_json.fetch("result")).to include("success" => false, "exit_code" => 1)
    end

    # @spec CONTAINER-RUNTIME-045
    it "captures a non-zero-exit translation error into the same report contract as a returned failure" do
      allow(runner).to receive(:start).and_raise(
        ExecutionRunners::ExecutionError.new("boom", exit_code: 17, stdout: "partial\n", stderr: "bad time")
      )

      result = run_benchmark

      expect(runner).to have_received(:cleanup).with(handle: handle, force: true)
      expect(result.execution_result).to be_failure
      expect(result.execution_result.exit_code).to eq(17)
      expect(result.execution_result.stdout).to eq("partial\n")
      expect(result.report.as_json.fetch("result")).to include("success" => false, "exit_code" => 17)
    end

    it "raises the cleanup failure when the workload's own failure was already captured in the report" do
      allow(runner).to receive(:start).and_raise(ExecutionRunners::StartupTimeoutError, "no startup output")
      allow(runner).to receive(:cleanup).and_raise(ExecutionRunners::Error, "teardown failed")

      expect { run_benchmark }.to raise_error(ExecutionRunners::Error, /teardown failed/)
    end

    it "keeps an unclassified workload bug visible when cleanup fails too" do
      allow(runner).to receive(:start).and_raise(ArgumentError, "not a runner contract error")
      allow(runner).to receive(:cleanup).and_raise(ExecutionRunners::Error, "teardown failed")

      expect { run_benchmark }.to raise_error(ArgumentError, /not a runner contract error/)
    end

    it "surfaces a cleanup failure when the workload itself succeeded" do
      allow(runner).to receive(:start).and_return(ExecutionRunners::ExecutionResult.success(stdout: "ok"))
      allow(runner).to receive(:cleanup).and_raise(ExecutionRunners::Error, "teardown failed")

      expect { run_benchmark }.to raise_error(ExecutionRunners::Error, /teardown failed/)
    end

    it "lets an unclassified workload bug propagate without building a report" do
      allow(runner).to receive(:start).and_raise(ArgumentError, "not a runner contract error")

      expect { run_benchmark }.to raise_error(ArgumentError, /not a runner contract error/)
      expect(runner).to have_received(:cleanup).with(handle: handle, force: true)
    end

    def run_benchmark
      described_class.run(
        runner: runner, spec: run_spec, command: "bin/conformance-task",
        dimension_results: dimension_results
      )
    end
  end
end
