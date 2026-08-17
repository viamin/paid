# frozen_string_literal: true

module ExecutionControls
  class Resolver
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, runner: nil, docker_host: nil)
      @agent_run = agent_run
      @runner = runner
      @docker_host = docker_host
    end

    def call
      controls.compact.select(&:enabled?).max_by(&:priority)
    end

    private

    attr_reader :agent_run, :runner, :docker_host

    def controls
      [
        ExecutionControl.enabled.global_scope.first,
        account_control,
        project_control,
        runner_control,
        backend_control
      ]
    end

    def account_control
      account_id = agent_run.project&.account_id
      return if account_id.blank?

      ExecutionControl.enabled.for_account_scope(account_id).first
    end

    def project_control
      return if agent_run.project_id.blank?

      ExecutionControl.enabled.for_project_scope(agent_run.project_id).first
    end

    def runner_control
      runner_id = runner&.id || agent_run.runner_id
      return if runner_id.blank?

      ExecutionControl.enabled.for_runner_scope(runner_id).first
    end

    # @spec EXEC-DISABLE-004
    def backend_control
      host = docker_host || resolve_docker_host
      return if host.blank?

      ExecutionControl.enabled.for_backend_scope(host.id).first
    end

    def resolve_docker_host
      identifier = agent_run.container_host.presence || agent_run.external_metadata&.[]("planned_container_host")
      return if identifier.blank?

      DockerHost.find_by(account_id: agent_run.project&.account_id, identifier: identifier)
    end
  end
end
