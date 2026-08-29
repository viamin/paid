# frozen_string_literal: true

module ExecutionRunners
  module ConformanceSuite
    # Runs a workload through a runner's own provision/start/cleanup
    # lifecycle and emits the runner_conformance_benchmark.v1 report from
    # timestamps captured around that real run. The no-shared-filesystem
    # conformance suite and future provider-comparison runs both call into
    # this so the benchmark payload always comes from a runner-owned
    # execution, never from test-only timestamp bookkeeping assembled
    # outside the runner contract.
    # @spec CONTAINER-RUNTIME-045
    class Benchmark
      Result = Data.define(:handle, :execution_result, :report)

      def self.run(runner:, spec:, command:, dimension_results:, fixture: ConformanceSuite.fixture_workload, &block)
        new(runner: runner, spec: spec, dimension_results: dimension_results, fixture: fixture)
          .run(command: command, &block)
      end

      def initialize(runner:, spec:, dimension_results:, fixture:)
        @runner = runner
        @spec = spec
        @dimension_results = dimension_results
        @fixture = fixture
      end

      def run(command:)
        timestamps = { provision_requested_at: Time.now.utc }
        handle = runner.provision(spec: spec)
        timestamps[:environment_ready_at] = Time.now.utc
        timestamps[:workload_started_at] = Time.now.utc

        first_output_at = nil
        execution_result = runner.start(handle: handle, command: command, timeout: 60, startup_timeout: 30,
          idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil) do |stream, chunk|
            first_output_at ||= Time.now.utc
            yield stream, chunk if block_given?
          end
        timestamps[:first_output_at] = first_output_at || timestamps.fetch(:workload_started_at)
        timestamps[:workload_finished_at] = Time.now.utc

        timestamps[:cleanup_requested_at] = Time.now.utc
        runner.cleanup(handle: handle, force: true)
        timestamps[:cleanup_finished_at] = Time.now.utc

        Result.new(
          handle: handle, execution_result: execution_result,
          report: build_report(timestamps, execution_result)
        )
      end

      private

      attr_reader :runner, :spec, :dimension_results, :fixture

      def build_report(timestamps, execution_result)
        BenchmarkReport.build(
          runner_type: runner.class.name.demodulize.underscore,
          runner_backend: spec.agent_run.container_host || "unknown",
          timestamps: timestamps,
          execution_result: execution_result,
          agent_run: spec.agent_run,
          dimension_results: dimension_results,
          fixture: fixture
        )
      end
    end
  end
end
