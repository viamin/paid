# frozen_string_literal: true

# Executes only a fixed, read-only runtime probe in the run's isolated
# environment. It deliberately has no user-supplied shell command or socket
# mount path; sidecars remain governed by their normal flag and image allowlist.
class PrerequisiteExecutionValidationJob < ApplicationJob
  queue_as :default

  NATIVE_ANALYZER = { "name" => "ruby", "command" => [ "ruby", "--version" ] }.freeze

  # @spec PARTIAL-CLOSEOUT-029 @spec PARTIAL-CLOSEOUT-030
  def perform(agent_run_id)
    run = AgentRun.find(agent_run_id)
    return if run.status == "cancelled"

    run.update!(status: "running", started_at: Time.current)
    preflight_sidecar!(run)
    run.provision_execution_environment
    Containers::McpProvisioner.new.provision(run)
    native_result = run.execute_in_execution_environment(NATIVE_ANALYZER.fetch("command"), stream: false)
    sidecar_result = probe_requested_sidecar(run)
    complete!(run, native_result, sidecar_result)
  rescue PrerequisiteExecutionUnavailable => e
    unavailable!(run, e.message)
  rescue Containers::Provision::Error, ExecutionRunners::Error => e
    failed!(run, e)
  ensure
    cleanup!(run) if run
  end

  private

  PrerequisiteExecutionUnavailable = Class.new(StandardError)

  def preflight_sidecar!(run)
    requested = run.external_metadata.dig("prerequisite_execution_validation", "requested_tool_name")
    return if requested.blank?

    unless FeatureFlags.enabled?(:marketplace_tool_sidecars, project: run.project)
      raise PrerequisiteExecutionUnavailable, "Marketplace tool sidecars are disabled; authorize the scoped pilot before retrying."
    end
    return if Array(run.tool_sidecar_snapshot).any? { |tool| tool["name"] == requested }

    raise PrerequisiteExecutionUnavailable, "Selected tool #{requested.inspect} is not attached to this run."
  end

  def complete!(run, result, sidecar_result)
    successful = result.success? && (sidecar_result.nil? || sidecar_result.success?)
    outcome = successful ? "executed" : "failed"
    run.update!(status: successful ? "completed" : "failed", completed_at: Time.current,
      verification_result: evidence(run, outcome: outcome, result: result, sidecar_result: sidecar_result))
  end

  def unavailable!(run, reason)
    run.update!(status: "failed", completed_at: Time.current,
      verification_result: evidence(run, outcome: "unavailable", reason: reason))
  end

  def failed!(run, error)
    run.update!(status: "failed", completed_at: Time.current, error_message: error.message,
      verification_result: evidence(run, outcome: "failed", reason: error.message))
  end

  def cleanup!(run)
    run.cleanup_execution_environment(force: true)
    run.reload
    run.update!(verification_result: run.verification_result.deep_merge(
      "prerequisite_execution_validation" => { "cleanup" => "completed", "cleaned_at" => Time.current.iso8601 }
    ))
  rescue Containers::Provision::Error, ExecutionRunners::Error => e
    run.update!(verification_result: run.verification_result.deep_merge(
      "prerequisite_execution_validation" => { "cleanup" => "failed", "cleanup_error" => e.message }
    ))
  end

  def probe_requested_sidecar(run)
    requested = run.external_metadata.dig("prerequisite_execution_validation", "requested_tool_name")
    return if requested.blank?

    endpoint = Array(run.tool_sidecar_endpoints).first
    raise PrerequisiteExecutionUnavailable, "Selected tool #{requested.inspect} did not provide an endpoint." if endpoint.blank?

    # The endpoint is produced by McpProvisioner, and is passed as an argv
    # value rather than interpolated into a shell command.
    run.execute_in_execution_environment(
      [ "ruby", "-rnet/http", "-ruri", "-e", "uri = URI(ARGV.fetch(0)); response = Net::HTTP.get_response(uri); puts response.code", endpoint ],
      stream: false
    )
  end

  def evidence(run, outcome:, result: nil, sidecar_result: nil, reason: nil)
    metadata = run.external_metadata.fetch("prerequisite_execution_validation")
    { "prerequisite_execution_validation" => {
      "outcome" => outcome, "issue_id" => metadata.fetch("issue_id"), "agent_run_id" => run.id,
      "analyzer" => NATIVE_ANALYZER, "requested_tool_name" => metadata["requested_tool_name"],
      "image" => run.runner_handle, "checkout" => run.base_commit_sha, "tool_endpoints" => run.tool_sidecar_endpoints,
      "stdout" => result&.[](:stdout), "stderr" => result&.[](:stderr), "exit_code" => result&.[](:exit_code),
      "sidecar_stdout" => sidecar_result&.[](:stdout), "sidecar_stderr" => sidecar_result&.[](:stderr),
      "sidecar_exit_code" => sidecar_result&.[](:exit_code),
      "reason" => reason, "captured_at" => Time.current.iso8601
    }.compact }
  end
end
