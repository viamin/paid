# frozen_string_literal: true

module PrerequisiteExecutions
  # Shared teardown for a validation attempt: tool sidecars via the
  # marketplace provisioner's cleanup, the run container via
  # AgentRun#cleanup_execution_environment. Records the cleanup disposition
  # as evidence on the validation whether the steps succeeded or not, and
  # never raises — cleanup failures are evidence, not aborts.
  #
  # @spec PREREQ-EXEC-012
  class Cleanup
    def self.call(validation, mcp_provisioner: Containers::McpProvisioner.new)
      new(validation, mcp_provisioner: mcp_provisioner).call
    end

    def initialize(validation, mcp_provisioner:)
      @validation = validation
      @mcp_provisioner = mcp_provisioner
    end

    def call
      run = validation.agent_run
      return {} if run.nil?

      disposition = {
        "sidecars" => cleanup_sidecars(run),
        "run_container" => cleanup_run_container(run)
      }
      validation.update!(
        evidence: validation.evidence.merge("cleanup" => disposition)
      )
      disposition
    end

    private

    attr_reader :validation, :mcp_provisioner

    def cleanup_sidecars(run)
      return "not_provisioned" if Array(run.tool_sidecar_container_ids).empty?

      mcp_provisioner.cleanup_tool_sidecars(run)
      run.reload
      Array(run.tool_sidecar_container_ids).empty? ? "cleaned" : "partial"
    rescue StandardError => e
      log_cleanup_failure("sidecars", e)
      "failed"
    end

    def cleanup_run_container(run)
      return "not_provisioned" if run.container_id.blank?

      run.cleanup_execution_environment(force: true)
      run.reload
      run.container_id.blank? ? "cleaned" : "partial"
    rescue StandardError => e
      log_cleanup_failure("run_container", e)
      "failed"
    end

    def log_cleanup_failure(surface, error)
      Rails.logger.warn(
        message: "prerequisite_executions.cleanup_failed",
        prerequisite_execution_validation_id: validation.id,
        surface: surface,
        error_class: error.class.name,
        error_message: error.message
      )
    end
  end
end
