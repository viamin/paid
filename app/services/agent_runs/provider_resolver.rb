# frozen_string_literal: true

module AgentRuns
  class ProviderResolver
    def self.call(...)
      new(...).call
    end

    def initialize(project:, goal:, requested_agent_type: nil, requested_provider_id: nil, respect_requested: true, logger: nil)
      @project = project
      @goal = goal
      @requested_agent_type = requested_agent_type
      @requested_provider_id = requested_provider_id
      @respect_requested = respect_requested
      @logger = logger
    end

    def call
      selection = requested_selection if respect_requested
      return selection if selection

      selection = project_preferred_agent_selection
      return selection if selection

      provider = default_provider
      return [ provider.id, Provider.agent_type_for(provider.provider_key) ] if provider

      fallback_from_settings
    end

    private

    attr_reader :project, :goal, :requested_agent_type, :requested_provider_id, :respect_requested, :logger

    def requested_selection
      provider = provider_for_id(requested_provider_id)
      return [ provider.id, Provider.agent_type_for(provider.provider_key) ] if provider && provider_runnable?(provider)
      return [ nil, requested_agent_type ] if agent_type_runnable?(requested_agent_type)

      log_unrunnable_requested_provider if requested_provider_id.present? || requested_agent_type.present?
      nil
    end

    def project_preferred_agent_selection
      agent_type = project.model_preferences["preferred_agent_type"]
      return unless agent_type.present? && agent_type_runnable?(agent_type)

      provider_key = Provider.provider_key_for_agent_type(agent_type)
      owner = project.effective_owner
      return [ nil, agent_type ] unless owner

      provider = owner.providers.find_by(provider_key: provider_key)
      provider ? [ provider.id, agent_type ] : [ nil, agent_type ]
    end

    def default_provider
      owner = project.effective_owner
      return unless owner

      settings = UserSettingsResolver.call(project: project, strict: false)
      base_provider = provider_from_settings(settings, owner)
      tenant_api_key_provider(base_provider || Provider.ensure_default_for(owner), owner) ||
        base_provider ||
        Provider.ensure_default_for(owner)
    end

    def provider_from_settings(settings, owner)
      return Provider.ensure_default_for(owner) unless settings

      identifier = settings.select_automated_provider_identifier(goal: goal) ||
        settings.default_provider_identifier_for_goal(goal)
      Provider.for_identifier(settings.user, identifier)
    end

    def tenant_api_key_provider(base_provider, owner)
      return unless base_provider

      service_type = ProviderSupport.api_service_type_for(base_provider.provider_key)
      api_key = project.account.tenant_setting&.provider_api_key_for(service_type)
      return unless api_key
      return unless api_key.compatible_with?(base_provider.provider_key)

      owner.providers.find_or_create_by!(
        provider_key: base_provider.provider_key,
        auth_type: "api_key",
        provider_api_key: api_key
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      owner.providers.find_by(
        provider_key: base_provider.provider_key,
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    def provider_for_id(provider_id)
      return if provider_id.blank?

      project.effective_owner&.providers&.find_by(id: provider_id)
    end

    def provider_runnable?(provider)
      ProviderSupport.container_executable_provider_key?(provider.provider_key)
    end

    def agent_type_runnable?(agent_type)
      return false if agent_type.blank?

      AgentRun::AGENT_TYPES.include?(agent_type) &&
        ProviderSupport.container_executable_provider_key?(Provider.provider_key_for_agent_type(agent_type))
    end

    def log_unrunnable_requested_provider
      logger&.warn(
        message: "agent_execution.requested_provider_not_runnable",
        project_id: project.id,
        requested_provider_id: requested_provider_id,
        requested_agent_type: requested_agent_type
      )
    end

    def fallback_from_settings
      enabled = Provider.first_enabled_for_owner(project.effective_owner)
      return [ enabled.id, Provider.agent_type_for(enabled.provider_key) ] if enabled

      first_key = ProviderSupport.container_executable_provider_keys.first
      agent_type = first_key ? Provider.agent_type_for(first_key) : "claude_code"
      [ nil, agent_type ]
    end
  end
end
