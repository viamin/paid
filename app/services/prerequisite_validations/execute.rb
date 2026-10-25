# frozen_string_literal: true

module PrerequisiteValidations
  # Runs a deliberately small technical prerequisite check in the run's
  # isolated execution environment. Callers supply only previously selected
  # analyzer and marketplace attachment identities; this class never makes a
  # control-plane shell available to repository content.
  # @spec PARTIAL-CLOSEOUT-030
  class Execute
    Result = Data.define(:status, :evidence, :message) do
      def successful? = status == "succeeded"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, analyzer:, sidecar_request: nil, scheduler: Containers::BackendScheduler,
      feature_flags: FeatureFlags)
      @agent_run = agent_run
      @analyzer = analyzer.stringify_keys
      @sidecar_request = sidecar_request&.stringify_keys
      @scheduler = scheduler
      @feature_flags = feature_flags
    end

    def call
      return record_unavailable("No compatible isolated execution backend is available.") unless compatible_backend?
      return record_unavailable("Marketplace tool sidecars are not authorized for this project.") if sidecar_requested? && !sidecars_authorized?

      @cleanup_required = true
      agent_run.provision_execution_environment
      native_result = execute(analyzer.fetch("command"))
      sidecar_result = execute_sidecar_request
      record_complete(native_result:, sidecar_result:)
    rescue Containers::Provision::Error, ExecutionRunners::Error => error
      record_failure("unavailable", error.message)
    rescue KeyError, ArgumentError => error
      record_failure("failed", error.message)
    ensure
      cleanup
    end

    private

    attr_reader :agent_run, :analyzer, :feature_flags, :scheduler, :sidecar_request

    def compatible_backend?
      scheduler.call(agent_run:).candidate_hosts.any?
    end

    def sidecar_requested? = sidecar_request.present?

    def sidecars_authorized?
      feature_flags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    def execute(command)
      result = agent_run.execute_in_execution_environment(command, stream: false)
      { "stdout" => result.stdout, "stderr" => result.stderr, "exit_code" => result.exit_code }
    end

    def execute_sidecar_request
      return nil unless sidecar_requested?

      endpoint = Array(agent_run.tool_sidecar_endpoints).find { |candidate| candidate["name"] == sidecar_request.fetch("name") }
      raise ArgumentError, "Selected tool sidecar is not available in this run." unless endpoint

      execute(sidecar_request.fetch("command")).merge("endpoint" => endpoint)
    end

    def record_complete(native_result:, sidecar_result:)
      status = [ native_result, sidecar_result ].compact.all? { |result| result["exit_code"].to_i.zero? } ? "succeeded" : "partial"
      record(status, native_result:, sidecar_result:)
    end

    def record_unavailable(message) = record("unavailable", message:)
    def record_failure(status, message) = record(status, message:)

    def record(status, native_result: nil, sidecar_result: nil, message: nil)
      evidence = {
        "status" => status,
        "image" => agent_run.external_metadata["image"],
        "checkout" => agent_run.base_commit_sha,
        "analyzer" => analyzer.slice("name", "version", "command"),
        "native" => native_result,
        "sidecar" => sidecar_result,
        "message" => message,
        "recorded_at" => Time.current.utc.iso8601
      }
      agent_run.update!(verification_result: agent_run.verification_result.merge("prerequisite_validation" => evidence))
      Result.new(status:, evidence:, message:)
    end

    def cleanup
      return unless @cleanup_required

      agent_run.cleanup_execution_environment
      agent_run.reload
      evidence = agent_run.verification_result.fetch("prerequisite_validation", {})
      agent_run.update!(verification_result: agent_run.verification_result.merge("prerequisite_validation" => evidence.merge("cleanup" => "completed")))
    rescue Containers::Provision::Error, ExecutionRunners::Error => error
      return unless agent_run.persisted?

      evidence = agent_run.verification_result.fetch("prerequisite_validation", {})
      agent_run.update!(verification_result: agent_run.verification_result.merge("prerequisite_validation" => evidence.merge("cleanup" => "failed", "cleanup_message" => error.message)))
    end
  end
end
