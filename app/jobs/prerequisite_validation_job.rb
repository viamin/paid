# frozen_string_literal: true

# Executes a fixed persisted contract only after the ordinary isolated AgentRun
# environment has been provisioned; no Inbox-provided shell input is accepted.
# @spec PREREQUISITE-VALIDATION-002
class PrerequisiteValidationJob < ApplicationJob
  queue_as :default

  def perform(agent_run_id)
    run = AgentRun.find(agent_run_id)
    return unless run.status == "queued"

    run.update!(status: "running", started_at: Time.current)
    run.provision_execution_environment
    result = run.execute_in_execution_environment(command(run), timeout: 120, stream: false)
    persist(run, execution: execution_identity(run), result: result_payload(result), state: result.success? ? "executed" : "failed")
    result.success? ? run.complete! : run.fail!(error: "Prerequisite validation command failed (exit #{result[:exit_code]}).")
  rescue Containers::McpProvisioner::Error, Containers::Provision::Error, ExecutionRunners::Error => error
    persist(run, state: "failed", error: error.message) if run
    run.fail!(error: error.message) if run && !run.finished?
  ensure
    cleanup(run) if run
  end

  private

  def command(run) = run.external_metadata.dig("prerequisite_validation", "native_analyzer", "command")

  def result_payload(result)
    { "stdout" => result[:stdout].to_s.truncate(10_000), "stderr" => result[:stderr].to_s.truncate(10_000), "exit_status" => result[:exit_code] }
  end

  def execution_identity(run)
    {
      "checkout" => run.base_commit_sha || run.worktree_path,
      "image" => run.authority_grants.dig("execution", "image"),
      "tool_endpoints" => run.tool_sidecar_endpoints
    }
  end

  def persist(run, updates)
    validation = run.external_metadata.fetch("prerequisite_validation").merge(updates.stringify_keys, "updated_at" => Time.current.iso8601)
    run.update!(external_metadata: run.external_metadata.merge("prerequisite_validation" => validation))
  end

  def cleanup(run)
    run.cleanup_execution_environment(force: true)
    persist(run, cleanup: { "completed_at" => Time.current.iso8601 })
  rescue Containers::Provision::Error, ExecutionRunners::Error => error
    persist(run, cleanup: { "error" => error.message })
  end
end
