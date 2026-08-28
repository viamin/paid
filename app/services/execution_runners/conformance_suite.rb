# frozen_string_literal: true

module ExecutionRunners
  # Production-readiness surface for the shared runner conformance suite
  # (#3358): the thirteen lifecycle dimensions the suite must exercise, the
  # canonical deterministic fixture workload, and the JSON benchmark capture
  # format (`runner_conformance_benchmark.v1`) used for provider comparison.
  # The executable checks live in the shared no-shared-filesystem conformance
  # examples; this module is the catalog and report contract they emit.
  # @spec CONTAINER-RUNTIME-045
  module ConformanceSuite
    SCHEMA_VERSION = "runner_conformance_benchmark.v1"
    FIXTURE_REPO_RELATIVE_PATH = "spec/fixtures/execution_runners/conformance_repo"
    DIMENSIONS = [
      {
        "key" => "provision_execution",
        "label" => "Provision execution",
        "activities" => [ "ProvisionContainerActivity" ],
        "description" => "Provision the primary execution environment."
      },
      {
        "key" => "clone_fixture_repository",
        "label" => "Clone fixture repository",
        "activities" => [ "CloneRepoActivity" ],
        "description" => "Clone the deterministic fixture repository inside the execution environment."
      },
      {
        "key" => "inject_configuration",
        "label" => "Inject configuration",
        "activities" => [ "ProvisionContainerActivity" ],
        "description" => "Inject standard environment, workspace, and run configuration."
      },
      {
        "key" => "provide_secrets_securely",
        "label" => "Provide secrets securely",
        "activities" => [ "ProvisionContainerActivity", "RunAgentActivity" ],
        "description" => "Deliver proxy-mode or direct-mode secrets without leaking secret values."
      },
      {
        "key" => "run_workload",
        "label" => "Run workload",
        "activities" => [ "RunAgentActivity" ],
        "description" => "Execute the fixture workload through the normal runner contract."
      },
      {
        "key" => "provision_service_dependencies",
        "label" => "Provision service dependencies",
        "activities" => [
          "ProvisionServicesActivity",
          "ProvisionMcpServersActivity",
          "ProvisionBrowserContainerActivity"
        ],
        "description" => "Provision supporting services, MCP servers, and browser sidecars."
      },
      {
        "key" => "retrieve_and_stream_logs",
        "label" => "Retrieve and stream logs",
        "activities" => [ "StreamingEventProcessor", "Containers::CollectMetrics" ],
        "description" => "Stream stdout/stderr and collect execution metrics without shared-host log files."
      },
      {
        "key" => "report_success_or_failure",
        "label" => "Report success or failure",
        "activities" => [ "RunAgentActivity" ],
        "description" => "Report exit code, stdout/stderr capture, and terminal status."
      },
      {
        "key" => "handle_non_zero_exits",
        "label" => "Handle non-zero exits",
        "activities" => [ "MarkAgentRunFailedActivity" ],
        "description" => "Classify non-zero exits and record the failure path."
      },
      {
        "key" => "enforce_timeout",
        "label" => "Enforce timeout",
        "activities" => [ "RunAgentActivity" ],
        "description" => "Enforce AGENT_TIMEOUT and classify timeout exits."
      },
      {
        "key" => "cancel_running_workload",
        "label" => "Cancel running workload",
        "activities" => [ "AgentRuns::Cancel", "RunAgentActivity" ],
        "description" => "Cancel a running workload through heartbeat-aware runner cancellation."
      },
      {
        "key" => "clean_up_resources",
        "label" => "Clean up resources",
        "activities" => [
          "CleanupContainerActivity",
          "CleanupServicesActivity",
          "CleanupWorktreeActivity",
          "CleanupMcpServersActivity"
        ],
        "description" => "Release the primary environment, services, workspace, and sidecars."
      },
      {
        "key" => "demonstrate_retry_and_idempotency",
        "label" => "Demonstrate retry and idempotency",
        "activities" => [ "Activities::IdempotencyKey" ],
        "description" => "Prove retry-safe provisioning and cleanup across crash windows."
      }
    ].freeze

    def self.fixture_workload
      {
        "name" => "runner-conformance-fixture",
        "relative_repo_path" => FIXTURE_REPO_RELATIVE_PATH,
        "entrypoint" => "bin/conformance-task",
        "expected_stdout" => "CONFORMANCE_OK",
        "expected_artifact_path" => "artifacts/conformance-result.json",
        "requires_llm" => false,
        "description" => "Minimal deterministic fixture that writes a JSON artifact and prints a fixed token."
      }
    end

    def self.dimension_catalog
      DIMENSIONS
    end

    class BenchmarkReport < Data.define(
      :schema_version,
      :generated_at,
      :fixture,
      :runner,
      :benchmark,
      :resource_usage,
      :cost,
      :dimensions,
      :result
    )
      class << self
        def build(runner_type:, runner_backend:, timestamps:, execution_result:, agent_run:,
                  dimension_results:, execution_usage: nil, fixture: ConformanceSuite.fixture_workload,
                  resource_usage: {})
          new(
            schema_version: SCHEMA_VERSION,
            generated_at: timestamps.fetch(:cleanup_finished_at).utc.iso8601,
            fixture: fixture,
            runner: {
              "runner_type" => runner_type.to_s,
              "runner_backend" => runner_backend.to_s
            },
            benchmark: {
              "provisioning_latency_ms" => milliseconds_between(
                timestamps.fetch(:provision_requested_at),
                timestamps.fetch(:environment_ready_at)
              ),
              "cold_start_latency_ms" => milliseconds_between(
                timestamps.fetch(:provision_requested_at),
                timestamps.fetch(:first_output_at)
              ),
              "execution_duration_ms" => milliseconds_between(
                timestamps.fetch(:workload_started_at),
                timestamps.fetch(:workload_finished_at)
              ),
              "cleanup_latency_ms" => milliseconds_between(
                timestamps.fetch(:cleanup_requested_at),
                timestamps.fetch(:cleanup_finished_at)
              )
            },
            resource_usage: default_resource_usage(
              agent_run: agent_run,
              execution_usage: execution_usage,
              overrides: resource_usage
            ),
            cost: {
              "estimated_infra_cost_cents" => execution_usage&.infra_cost_cents || agent_run.infra_cost_cents,
              "billed_duration_seconds" => execution_usage&.billed_duration_seconds || agent_run.billed_duration_seconds,
              "rate_cents_per_hour" => execution_usage&.rate_cents_per_hour,
              "provider_resource_id" => execution_usage&.provider_resource_id
            }.compact,
            dimensions: normalize_dimensions(dimension_results),
            result: {
              "success" => execution_result.success?,
              "exit_code" => execution_result.exit_code,
              "oom_killed" => execution_result.oom_killed,
              "stdout_bytes" => execution_result.stdout.to_s.bytesize,
              "stderr_bytes" => execution_result.stderr.to_s.bytesize
            }
          )
        end

        def default_dimension_results(passed:, evidence: {})
          validate_catalog_keys!(passed, label: "Unknown conformance dimensions")
          passed_keys = normalize_catalog_keys(passed)
          evidence_by_key = normalize_catalog_hash(evidence)

          ConformanceSuite.dimension_catalog.map do |dimension|
            key = dimension.fetch("key")
            {
              "key" => key,
              "label" => dimension.fetch("label"),
              "status" => passed_keys.include?(key) ? "pass" : "not_exercised",
              "activities" => dimension.fetch("activities"),
              "description" => dimension.fetch("description"),
              "evidence" => evidence_by_key[key]
            }.compact
          end
        end

        private

        def normalize_dimensions(dimension_results)
          keys = dimension_results.map { |entry| entry.fetch("key") }
          duplicates = keys.tally.filter_map { |key, count| key if count > 1 }
          raise ArgumentError, "Duplicate conformance dimensions: #{duplicates.join(', ')}" if duplicates.any?

          unknown = keys - catalog_keys
          raise ArgumentError, "Unknown conformance dimensions: #{unknown.join(', ')}" if unknown.any?

          missing = ConformanceSuite.dimension_catalog.map { |entry| entry.fetch("key") } - keys
          raise ArgumentError, "Missing conformance dimensions: #{missing.join(', ')}" if missing.any?

          dimension_results
        end

        def validate_catalog_keys!(keys, label:)
          unknown = normalize_catalog_keys(keys) - catalog_keys
          raise ArgumentError, "#{label}: #{unknown.join(', ')}" if unknown.any?
        end

        def normalize_catalog_hash(hash)
          validate_catalog_keys!(hash.keys, label: "Unknown conformance dimensions")
          hash.transform_keys(&:to_s)
        end

        def normalize_catalog_keys(keys)
          keys.map(&:to_s)
        end

        def catalog_keys
          @catalog_keys ||= ConformanceSuite.dimension_catalog.map { |dimension| dimension.fetch("key") }
        end

        def milliseconds_between(started_at, finished_at)
          ((finished_at - started_at) * 1000).to_i
        end

        def default_resource_usage(agent_run:, execution_usage:, overrides:)
          {
            "peak_cpu_percent" => agent_run.peak_cpu_percent,
            "peak_memory_bytes" => agent_run.peak_memory_bytes,
            "peak_disk_bytes" => nil,
            "requested_disk_gb" => execution_usage&.requested_disk_gb,
            "container_metric_samples" => agent_run.container_metrics_count
          }.merge(overrides.compact)
        end
      end

      def to_h
        {
          schema_version: schema_version,
          generated_at: generated_at,
          fixture: fixture,
          runner: runner,
          benchmark: benchmark,
          resource_usage: resource_usage,
          cost: cost,
          dimensions: dimensions,
          result: result
        }
      end

      def as_json(*)
        ExecutionRunners.json_value(to_h)
      end
    end
  end
end
