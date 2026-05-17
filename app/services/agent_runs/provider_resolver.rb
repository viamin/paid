# frozen_string_literal: true

module AgentRuns
  class ProviderResolver
    def self.call(...)
      new(...).call
    end

    def self.selected_provider(project:, provider_id:)
      return if provider_id.blank?

      project.effective_owner&.providers&.kept_only&.find_by(id: provider_id)
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

      provider = owner.providers.kept_only.find_by(provider_key: provider_key)
      provider ? [ provider.id, agent_type ] : [ nil, agent_type ]
    end

    def default_provider
      owner = project.effective_owner
      return unless owner

      settings = UserSettingsResolver.call(project: project, strict: false)
      selected_provider = selected_provider_from_settings(settings, owner)
      configured_provider = configured_provider_from_raw_settings(settings)
      base_provider = runnable_provider(selected_provider) || runnable_provider(configured_provider)
      fallback_provider = Provider.first_enabled_for_owner(owner) || Provider.ensure_default_for(owner)
      tenant_api_key_provider(base_provider, owner) ||
        base_provider ||
        tenant_api_key_provider(configured_provider, owner) ||
        tenant_api_key_provider(fallback_provider, owner) ||
        fallback_provider
    end

    def selected_provider_from_settings(settings, owner)
      return Provider.ensure_default_for(owner) unless settings

      identifier = settings.select_automated_provider_identifier(goal: goal) ||
        settings.default_provider_identifier_for_goal(goal)
      Provider.for_identifier(settings.user, identifier)
    end

    def configured_provider_from_raw_settings(settings)
      return unless settings

      identifier = settings.default_agent_providers_by_goal[goal.to_s].presence || settings.default_agent_provider
      Provider.for_identifier(settings.user, identifier)
    end

    def runnable_provider(provider)
      return unless provider&.enabled_for_agent_runs?
      return unless provider_runnable?(provider)

      provider
    end

    def tenant_api_key_provider(base_provider, owner)
      return unless base_provider
      return unless provider_runnable?(base_provider)

      service_type = tenant_api_key_service_type_for(base_provider)
      return unless service_type

      api_key = project.account.tenant_setting&.provider_api_key_for(service_type)
      return unless api_key
      return unless api_key.compatible_with?(base_provider.provider_key)

      owner.providers.kept_only.find_or_create_by!(
        provider_key: base_provider.provider_key,
        auth_type: "api_key",
        provider_api_key: api_key
      ) do |provider|
        provider.config = tenant_api_key_provider_config(base_provider, api_key)
      end.tap do |provider|
        # Config can drift between calls (e.g. tenant changes their Pi model
        # preference in tenant_settings without rotating the API key). Sync it
        # on every materialisation so the next agent run picks up the change.
        fresh_config = tenant_api_key_provider_config(base_provider, api_key)
        provider.update!(config: fresh_config) if fresh_config != provider.config
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      owner.providers.kept_only.find_by(
        provider_key: base_provider.provider_key,
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    def tenant_api_key_service_type_for(base_provider)
      static = ProviderSupport.api_service_type_for(base_provider.provider_key)
      return static if static.present?
      return base_provider.pi_required_api_service_type if base_provider.provider_key == "pi"

      nil
    end

    def tenant_api_key_provider_config(base_provider, api_key)
      return {} unless base_provider.provider_key == "pi"

      config = {
        "pi" => {
          "api_provider" => api_key.api_service_type
        }
      }

      model = project.account.tenant_setting&.model_preference_for("pi").to_s.presence
      config["pi"]["model"] = model if model
      config
    end

    def provider_for_id(provider_id)
      self.class.selected_provider(project: project, provider_id: provider_id)
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
