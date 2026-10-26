# frozen_string_literal: true

module PartialCloseouts
  # Executes a bounded, pre-authorized technical check in an AgentRun's normal
  # isolated environment. Commands are supplied by the trusted action contract;
  # this service never exposes a host shell or Docker socket to an operator.
  # @spec PARTIAL-CLOSEOUT-031
  class TechnicalPrerequisiteValidation
    Result = Data.define(:status, :evidence)

    def self.call(...) = new(...).call

    def initialize(agent_run:, analyzer:, command:, tool_name: nil, tool_image: nil, timeout: nil)
      @agent_run = agent_run
      @analyzer = analyzer
      @command = command
      @tool_name = tool_name
      @tool_image = tool_image
      @timeout = timeout
    end

    def call
      return persist_unavailable unless plan.ready?

      provision_and_execute
    rescue Containers::Provision::Error, Containers::McpProvisioner::Error => error
      persist_terminal(:failed, error: error.message)
    rescue SignalException => error
      persist_terminal(:cancelled, error: error.message)
    ensure
      cleanup! if plan&.ready?
    end

    private

    attr_reader :agent_run, :analyzer, :command, :tool_name, :tool_image, :timeout

    def plan
      @plan ||= TechnicalPrerequisitePlan.call(agent_run:, tool_name: tool_name || analyzer, tool_image:)
    end

    def provision_and_execute
      agent_run.provision_execution_environment
      runner.provision_mcp_servers(agent_run:, network: Containers::Provision.network_for(agent_run:))
      result = agent_run.execute_in_execution_environment(command, timeout:, stream: false)
      status = result.success? ? :succeeded : :failed
      persist_terminal(status, result:)
    end

    def persist_unavailable
      persist(:unavailable, action: plan.action, scheduler: plan.evidence)
    end

    def persist_terminal(status, result: nil, error: nil)
      persist(status, scheduler: plan.evidence, result: result_evidence(result), error: error)
    end

    def persist(status, action: nil, scheduler: nil, result: nil, error: nil)
      evidence = {
        "status" => status.to_s, "analyzer" => analyzer, "command" => command,
        "checkout" => agent_run.base_commit_sha, "tool" => tool_name, "tool_image" => tool_image,
        "scheduler" => scheduler, "result" => result, "action" => action, "error" => error,
        "endpoint_response" => agent_run.tool_sidecar_endpoints
      }.compact
      agent_run.update!(external_metadata: agent_run.external_metadata.merge("technical_prerequisite_validation" => evidence))
      Result.new(status:, evidence:)
    end

    def result_evidence(result)
      return unless result

      { "stdout" => result[:stdout].to_s, "stderr" => result[:stderr].to_s, "exit_code" => result[:exit_code] }
    end

    def cleanup!
      runner.cleanup_mcp_servers(agent_run:)
      agent_run.cleanup_execution_environment
      update_cleanup_evidence
    end

    def update_cleanup_evidence
      evidence = agent_run.external_metadata.fetch("technical_prerequisite_validation", {})
      agent_run.update!(external_metadata: agent_run.external_metadata.merge(
        "technical_prerequisite_validation" => evidence.merge(
          "cleanup" => { "tool_sidecars" => "completed", "environment" => "completed" }
        )
      ))
    end

    def runner = @runner ||= ExecutionRunners.resolve_for(agent_run)
  end
end
