# frozen_string_literal: true

module AgentRuns
  class ProviderResolver < RunnerResolver
    def self.call(**kwargs)
      new(**normalize_legacy_kwargs(kwargs)).call
    end

    def self.selected_provider(project:, provider_id:)
      selected_runner(project: project, runner_id: provider_id)
    end

    def self.normalize_legacy_kwargs(kwargs)
      normalized = kwargs.dup
      requested_provider_id = normalized.delete(:requested_provider_id)
      normalized[:requested_runner_id] ||= requested_provider_id
      normalized
    end

    def initialize(**kwargs)
      super(**self.class.normalize_legacy_kwargs(kwargs))
    end

    private

    def container_executable_runner_keys
      ProviderSupport.container_executable_provider_keys
    end

    def container_executable_runner_key?(runner_key)
      ProviderSupport.container_executable_provider_key?(runner_key)
    end

    def runner_key_for_agent_type(agent_type)
      ProviderSupport.provider_key_for_agent_type(agent_type)
    end

    def agent_type_for_runner_key(runner_key)
      ProviderSupport.agent_type_for(runner_key)
    end

    def default_runner
      owner = project.effective_owner
      return unless owner

      settings = UserSettingsResolver.call(project: project, strict: false)
      selected_provider = selected_runner_from_settings(settings, owner)
      configured_provider = configured_runner_from_raw_settings(settings)
      base_provider = runnable_runner(selected_provider) || runnable_runner(configured_provider)
      fallback_provider = Provider.first_enabled_for_owner(owner) || Provider.ensure_default_for(owner)
      account_managed_runner(base_provider, owner) ||
        base_provider ||
        account_managed_runner(configured_provider, owner) ||
        account_managed_runner(fallback_provider, owner) ||
        fallback_provider
    end

    def selected_runner_from_settings(settings, owner)
      return Provider.ensure_default_for(owner) unless settings

      identifier = settings.select_automated_provider_identifier(goal: goal) ||
        settings.default_provider_identifier_for_goal(goal)
      Provider.for_identifier(settings.user, identifier)
    end

    def configured_runner_from_raw_settings(settings)
      return unless settings

      identifier = settings.default_agent_providers_by_goal[goal.to_s].presence || settings.default_agent_provider
      Provider.for_identifier(settings.user, identifier)
    end

    def runnable_runner(provider)
      return unless provider&.enabled_for_agent_runs?
      return unless runner_runnable?(provider)

      provider
    end

    def account_managed_runner(base_provider, owner)
      return unless base_provider
      return unless runner_runnable?(base_provider)

      credential = resolve_account_credential(base_provider)
      return unless credential.present?
      return if credential.provider_api_key? && !credential.provider_api_key.compatible_with?(base_provider.provider_key)

      # Ensure the configured model exists in the LlmModel table before
      # validation runs on the new provider record. Direct-outbound validations
      # (direct_outbound_config_models_must_exist_in_catalog) upsert missing
      # entries as catalog_source: "manual" rows, so this pre-seed is only
      # needed when we want the row visible to model selection without the
      # provider save in flight.
      provider_config = account_managed_provider_config(base_provider, credential)
      seed_account_managed_model(base_provider, credential)

      owner.providers.kept_only.find_or_create_by!(
        provider_key: base_provider.provider_key,
        auth_type: "api_key",
        provider_api_key: credential.provider_api_key,
        integration_credential: credential.integration_credential
      ) do |provider|
        provider.config = provider_config
      end.tap do |provider|
        # Config can drift between calls (for example, tenant Pi model changes).
        provider.update!(config: provider_config) if provider_config != provider.config
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      owner.providers.kept_only.find_by(
        provider_key: base_provider.provider_key,
        auth_type: "api_key",
        provider_api_key: credential&.provider_api_key,
        integration_credential: credential&.integration_credential
      )
    end

    def account_credential_service_type_for(base_provider)
      static = ProviderSupport.api_service_type_for(base_provider.provider_key)
      return static if static.present?
      return base_provider.pi_required_api_service_type if base_provider.provider_key == "pi"

      nil
    end

    def account_managed_provider_config(base_provider, credential)
      return {} unless base_provider.provider_key == "pi"

      config = {
        "pi" => {
          "api_provider" => credential.provider_api_key&.api_service_type || account_credential_service_type_for(base_provider)
        }
      }

      model = project.account.tenant_setting&.model_preference_for("pi").to_s.presence
      config["pi"]["model"] = model if model
      config
    end

    def runner_for_id(provider_id)
      self.class.selected_provider(project: project, provider_id: provider_id)
    end

    def runner_runnable?(provider)
      ProviderSupport.container_executable_provider_key?(provider.provider_key)
    end

    def agent_type_runnable?(agent_type)
      return false if agent_type.blank?

      AgentRun::AGENT_TYPES.include?(agent_type) &&
        ProviderSupport.container_executable_provider_key?(Provider.provider_key_for_agent_type(agent_type))
    end

    def log_unrunnable_requested_runner
      logger&.warn(
        message: "agent_execution.requested_provider_not_runnable",
        project_id: project.id,
        requested_provider_id: requested_runner_id,
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
