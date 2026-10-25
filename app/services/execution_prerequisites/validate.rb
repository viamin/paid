# frozen_string_literal: true

module ExecutionPrerequisites
  # Runs the bounded, recorder-owned execution proof used by an Inbox
  # prerequisite. It deliberately accepts only a fixed native probe: callers
  # cannot turn this recovery path into host-shell access.
  # @spec PARTIAL-CLOSEOUT-028
  class Validate
    NATIVE_ANALYZER_COMMAND = [ "ruby", "--version" ].freeze
    REQUIRED_CAPABILITIES = ExecutionRunners::CapabilityRequirements.new(
      capabilities: %i[direct_exec persistent_workspace]
    )

    def self.call(...) = new(...).call

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      return recorded_result if agent_run.finished?

      agent_run.start!
      return record_unavailable!(authorization_message) if authorization_message
      return record_unavailable!(capability_result.error_message) unless capability_result.compatible

      execute_probe!
    rescue Containers::Provision::Error, ExecutionRunners::Error => error
      record_failure!(error)
    ensure
      cleanup!
    end

    private

    attr_reader :agent_run

    def execute_probe!
      agent_run.provision_execution_environment
      result = agent_run.execute_in_execution_environment(NATIVE_ANALYZER_COMMAND, stream: false)
      artifact = base_artifact.merge(
        "status" => result.success? ? "succeeded" : "failed",
        "stdout" => result[:stdout].to_s,
        "stderr" => result[:stderr].to_s,
        "exit_code" => result[:exit_code]
      )
      persist!(artifact)
      result.success? ? agent_run.complete! : agent_run.fail!(error: "Native analyzer exited #{result[:exit_code]}")
      artifact
    end

    def cleanup!
      agent_run.cleanup_execution_environment(force: true)
      persist!(agent_run.verification_result.merge("cleanup" => "succeeded")) if agent_run.verification_result.present?
    rescue Containers::Provision::Error, ExecutionRunners::Error => error
      persist!(agent_run.verification_result.merge("cleanup" => "failed", "cleanup_error" => error.message))
    end

    def record_unavailable!(message)
      artifact = base_artifact.merge("status" => "unavailable", "reason" => message)
      persist!(artifact)
      agent_run.fail!(error: message)
      artifact
    end

    def record_failure!(error)
      artifact = base_artifact.merge("status" => "failed", "reason" => error.message)
      persist!(artifact)
      agent_run.fail!(error: error.message)
      artifact
    end

    def persist!(artifact)
      agent_run.update!(verification_result: artifact)
      agent_run.log!("system", artifact.to_json)
    end

    def recorded_result = agent_run.verification_result

    def base_artifact
      {
        "contract" => "technical_prerequisite_execution_v1",
        "native_analyzer" => "ruby",
        "command" => NATIVE_ANALYZER_COMMAND,
        "checkout" => agent_run.base_commit_sha,
        "tool_sidecars" => agent_run.tool_sidecar_snapshot,
        "recorded_at" => Time.current.iso8601
      }
    end

    def authorization_message
      return unless agent_run.tool_sidecar_snapshot.present?
      return if FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)

      "Tool sidecars are attached but marketplace_tool_sidecars is disabled. Enable the scoped pilot flag before retrying."
    end

    def capability_result
      @capability_result ||= ExecutionRunners.resolve_for(agent_run).class.capability_compatibility_for(
        requirements: REQUIRED_CAPABILITIES,
        backend: Containers.backend_for(agent_run.workspace_volume_host),
        agent_run:
      )
    end
  end
end
