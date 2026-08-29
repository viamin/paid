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

      def run(command:, &block)
        timestamps = { provision_requested_at: Time.now.utc }
        handle = runner.provision(spec: spec)
        timestamps[:environment_ready_at] = Time.now.utc
        timestamps[:workload_started_at] = Time.now.utc

        execution_result = execute_with_cleanup(
          handle: handle, command: command, timestamps: timestamps, &block
        )

        Result.new(
          handle: handle, execution_result: execution_result,
          report: build_report(handle, timestamps, execution_result)
        )
      end

      private

      attr_reader :runner, :spec, :dimension_results, :fixture

      # The environment provisioned before this call has to be released
      # whether the workload succeeds, fails, or raises an unclassified bug,
      # so cleanup runs from an ensure rather than only on the happy path.
      # Classified runner failures never reach this rescue — {#execute}
      # converts them into a reportable ExecutionResult so build_report still
      # runs for them. Only a bug propagating out of {#execute} lands here.
      def execute_with_cleanup(handle:, command:, timestamps:, &block)
        workload_error = nil
        execute(handle: handle, command: command, timestamps: timestamps, &block)
      rescue StandardError => error
        workload_error = error
        raise
      ensure
        capture_cleanup(handle: handle, timestamps: timestamps, failure: workload_error)
      end

      # The runner contract allows #start to raise for a classified failure
      # (timeout, startup failure, non-zero exit translation) instead of
      # returning a failing ExecutionResult. That outcome is captured here as
      # an ExecutionResult, the same shape a runner returns for a failing
      # workload, so the benchmark report still gets built for it — a runner
      # signaling failure by raising must produce the same
      # runner_conformance_benchmark.v1 payload as one that returns normally.
      def execute(handle:, command:, timestamps:)
        first_output_at = nil
        timeout = spec.resources&.timeout_seconds || ExecutionResources.profile("standard").timeout_seconds
        result = runner.start(handle: handle, command: command, timeout: timeout, startup_timeout: timeout,
          idle_timeout: timeout, abort_patterns: nil, preparation: nil, heartbeat_path: nil) do |stream, chunk|
            first_output_at ||= Time.now.utc
            yield stream, chunk if block_given?
          end
        record_completion_timestamps(timestamps, first_output_at)
        result
      rescue ExecutionRunners::Error => error
        record_completion_timestamps(timestamps, first_output_at)
        failure_result_for(error)
      end

      # first_output_at stays nil when the workload never streamed any output
      # before #start raised (e.g. StartupTimeoutError) — BenchmarkReport
      # must null out cold_start_latency_ms for that run rather than
      # reporting a fabricated near-zero latency.
      def record_completion_timestamps(timestamps, first_output_at)
        timestamps[:first_output_at] = first_output_at
        timestamps[:workload_finished_at] = Time.now.utc
      end

      # Mirrors the shape a runner returns from #start for a failing
      # workload (see {ExecutionRunners::LocalDockerRunner#translate_result})
      # so {BenchmarkReport.build} sees one ExecutionResult contract
      # regardless of whether the runner raised or returned.
      def failure_result_for(error)
        return ExecutionResult.failure(exit_code: 1, stderr: error.message) unless error.is_a?(ExecutionError)

        ExecutionResult.failure(
          exit_code: error.exit_code || 1, stdout: error.stdout.to_s, stderr: error.stderr.to_s
        )
      end

      # A cleanup failure raised while +failure+ (an unclassified bug already
      # propagating) is present is logged rather than raised: replacing that
      # error would hide the bug the benchmark run set out to surface. On
      # every other path — including a classified runner failure {#execute}
      # already converted into a report — a cleanup failure is itself a
      # conformance failure and propagates normally.
      def capture_cleanup(handle:, timestamps:, failure:)
        timestamps[:cleanup_requested_at] = Time.now.utc
        runner.cleanup(handle: handle, force: true)
        timestamps[:cleanup_finished_at] = Time.now.utc
      rescue StandardError => error
        raise if failure.nil?

        Rails.logger.warn(
          message: "container_manager.conformance_cleanup_failed",
          runner_type: handle.runner_type,
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def build_report(handle, timestamps, execution_result)
        BenchmarkReport.build(
          runner_type: handle.runner_type,
          runner_backend: handle.host || "unknown",
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
