# frozen_string_literal: true

module AgentRuns
  class RunnerResolver
    def self.call(...)
      new(...).call
    end

    def self.selected_runner(project:, runner_id:)
      return if runner_id.blank?

      project.effective_owner&.runners&.kept_only&.find_by(id: runner_id)
    end

    def initialize(project:, goal:, requested_agent_type: nil, requested_runner_id: nil, respect_requested: true, logger: nil)
      @project = project
      @goal = goal
      @requested_agent_type = requested_agent_type
      @requested_runner_id = requested_runner_id
      @respect_requested = respect_requested
      @logger = logger
    end

    def call
      selection = requested_selection if respect_requested
      return selection if selection

      selection = project_preferred_agent_selection
      return selection if selection

      runner = default_runner
      return [ runner.id, Runner.agent_type_for(runner.runner_key) ] if runner

      fallback_from_settings
    end

    private

    attr_reader :project, :goal, :requested_agent_type, :requested_runner_id, :respect_requested, :logger

    def requested_selection
      runner = runner_for_id(requested_runner_id)
      return [ runner.id, Runner.agent_type_for(runner.runner_key) ] if runner && runner_runnable?(runner)
      return [ nil, requested_agent_type ] if agent_type_runnable?(requested_agent_type)

      log_unrunnable_requested_runner if requested_runner_id.present? || requested_agent_type.present?
      nil
    end

    def project_preferred_agent_selection
      agent_type = project.model_preferences["preferred_agent_type"]
      return unless agent_type.present? && agent_type_runnable?(agent_type)

      runner_key = Runner.runner_key_for_agent_type(agent_type)
      owner = project.effective_owner
      return [ nil, agent_type ] unless owner

      runner = owner.runners.kept_only.find_by(runner_key: runner_key)
      runner ? [ runner.id, agent_type ] : [ nil, agent_type ]
    end

    def default_runner
      owner = project.effective_owner
      return unless owner

      settings = UserSettingsResolver.call(project: project, strict: false)
      selected_runner = selected_runner_from_settings(settings, owner)
      configured_runner = configured_runner_from_raw_settings(settings)
      base_runner = runnable_runner(selected_runner) || runnable_runner(configured_runner)
      fallback_runner = Runner.first_enabled_for_owner(owner) || Runner.ensure_default_for(owner)
      tenant_api_key_runner(base_runner, owner) ||
        base_runner ||
        tenant_api_key_runner(configured_runner, owner) ||
        tenant_api_key_runner(fallback_runner, owner) ||
        fallback_runner
    end

    def selected_runner_from_settings(settings, owner)
      return Runner.ensure_default_for(owner) unless settings

      identifier = settings.select_automated_runner_identifier(goal: goal) ||
        settings.default_runner_identifier_for_goal(goal)
      Runner.for_identifier(settings.user, identifier)
    end

    def configured_runner_from_raw_settings(settings)
      return unless settings

      identifier = settings.default_agent_runners_by_goal[goal.to_s].presence || settings.default_agent_runner
      Runner.for_identifier(settings.user, identifier)
    end

    def runnable_runner(runner)
      return unless runner&.enabled_for_agent_runs?
      return unless runner_runnable?(runner)

      runner
    end

    def tenant_api_key_runner(base_runner, owner)
      return unless base_runner
      return unless runner_runnable?(base_runner)

      service_type = RunnerSupport.api_service_type_for(base_runner.runner_key)
      api_key = project.account.tenant_setting&.provider_api_key_for(service_type)
      return unless api_key
      return unless api_key.compatible_with?(base_runner.runner_key)

      owner.runners.kept_only.find_or_create_by!(
        runner_key: base_runner.runner_key,
        auth_type: "api_key",
        provider_api_key: api_key
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      owner.runners.kept_only.find_by(
        runner_key: base_runner.runner_key,
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    def runner_for_id(runner_id)
      self.class.selected_runner(project: project, runner_id: runner_id)
    end

    def runner_runnable?(runner)
      RunnerSupport.container_executable_runner_key?(runner.runner_key)
    end

    def agent_type_runnable?(agent_type)
      return false if agent_type.blank?

      AgentRun::AGENT_TYPES.include?(agent_type) &&
        RunnerSupport.container_executable_runner_key?(Runner.runner_key_for_agent_type(agent_type))
    end

    def log_unrunnable_requested_runner
      logger&.warn(
        message: "agent_execution.requested_runner_not_runnable",
        project_id: project.id,
        requested_runner_id: requested_runner_id,
        requested_agent_type: requested_agent_type
      )
    end

    def fallback_from_settings
      enabled = Runner.first_enabled_for_owner(project.effective_owner)
      return [ enabled.id, Runner.agent_type_for(enabled.runner_key) ] if enabled

      first_key = RunnerSupport.container_executable_runner_keys.first
      agent_type = first_key ? Runner.agent_type_for(first_key) : "claude_code"
      [ nil, agent_type ]
    end
  end
end
