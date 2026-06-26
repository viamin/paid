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

    # +exclude_runner_ids+ (dequeue late-binding only) holds runner ids that
    # already failed preflight during the current ProcessRunQueueJob pass.
    # The resolver treats them as unavailable so a queued run is never pinned
    # back to a runner known-unhealthy this pass; it falls through to a
    # healthy alternative instead. Empty for all other callers.
    def initialize(project:, goal:, requested_agent_type: nil, requested_runner_id: nil, respect_requested: true,
                   exclude_runner_ids: [], logger: nil)
      @project = project
      @goal = goal
      @requested_agent_type = requested_agent_type
      @requested_runner_id = requested_runner_id
      @respect_requested = respect_requested
      @exclude_runner_ids = Array(exclude_runner_ids)
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

    attr_reader :project, :goal, :requested_agent_type, :requested_runner_id, :respect_requested, :exclude_runner_ids, :logger

    # True when this runner instance already failed preflight during the
    # current dequeue pass and must not be re-selected.
    def excluded?(runner)
      runner.present? && exclude_runner_ids.include?(runner.id)
    end

    # Returns the first non-excluded candidate from the given runners.
    def first_allowed(*candidates)
      candidates.find { |runner| runner.present? && exclude_runner_ids.exclude?(runner.id) }
    end

    def requested_selection
      runner = runner_for_id(requested_runner_id)
      if runner && runner_runnable?(runner) && !excluded?(runner)
        return [ runner.id, agent_type_for_runner_key(runner.runner_key) ]
      end
      return [ nil, requested_agent_type ] if agent_type_runnable?(requested_agent_type)

      log_unrunnable_requested_runner if requested_runner_id.present? || requested_agent_type.present?
      nil
    end

    def project_preferred_agent_selection
      agent_type = project.model_preferences["preferred_agent_type"]
      return unless agent_type.present? && agent_type_runnable?(agent_type)

      runner_key = runner_key_for_agent_type(agent_type)
      owner = project.effective_owner
      return [ nil, agent_type ] unless owner

      runner = owner.runners.kept_only.find_by(runner_key: runner_key)
      # Preferred runner failed preflight earlier this dequeue pass: fall
      # through to default/fallback selection so a healthy alternative can
      # serve the run instead of being pinned back to the unhealthy one.
      return nil if runner && excluded?(runner)
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

      # Walk the preference chain in priority order but skip any candidate
      # that failed preflight this dequeue pass, so the run lands on a
      # healthy alternative rather than being re-pinned to a bad runner.
      first_allowed(
        account_managed_runner(base_runner, owner),
        base_runner,
        account_managed_runner(configured_runner, owner),
        account_managed_runner(fallback_runner, owner),
        fallback_runner
      ) || first_enabled_for_owner(owner)
    end

    def selected_runner_from_settings(settings, owner)
      return ensure_default_for(owner) unless settings

      identifier = settings.select_automated_runner_identifier(goal: goal) ||
        settings.default_runner_identifier_for_goal(goal)
      runner_for_identifier(settings.user, identifier)
    end

    def configured_runner_from_raw_settings(settings)
      return unless settings

      identifier = settings.default_agent_runners_by_goal[goal.to_s].presence || settings.default_agent_runner
      runner_for_identifier(settings.user, identifier)
    end

    def runnable_runner(runner)
      return unless runner&.enabled_for_agent_runs?
      return unless runner_runnable?(runner)

      runner
    end

    def account_managed_runner(base_runner, owner)
      return unless base_runner
      return unless runner_runnable?(base_runner)

      credential = resolve_account_credential(base_runner)
      return unless credential.present?
      return if credential.provider_api_key? && !credential.provider_api_key.compatible_with?(base_runner.runner_key)

      # Ensure the configured model exists in the LlmModel table before
      # validation runs on the new runner record. Direct-outbound validations
      # reject model IDs whose existing catalog row has a different provider
      # (see direct_outbound_config_models_must_exist_in_catalog), and
      # the runner's before_save callback materializes a missing model id as
      # a manual catalog row (#2669).
      seed_account_managed_model(base_runner, credential)

      owner.runners.kept_only.find_or_create_by!(
        runner_key: base_runner.runner_key,
        auth_type: "api_key",
        provider_api_key: credential.provider_api_key,
        integration_credential: credential.integration_credential
      ) do |runner|
        runner.config = account_managed_runner_config(base_runner, credential)
      end.tap do |runner|
        config = account_managed_runner_config(base_runner, credential)
        runner.update!(config: config) if config != runner.config
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      owner.runners.kept_only.find_by(
        runner_key: base_runner.runner_key,
        auth_type: "api_key",
        provider_api_key: credential&.provider_api_key,
        integration_credential: credential&.integration_credential
      )
    end

    def resolve_account_credential(base_runner)
      LlmCredentials::AccountResolver.call(
        account: project.account,
        runner_key: base_runner.runner_key,
        api_service_type: account_credential_service_type_for(base_runner),
        tenant_setting: project.account.tenant_setting
      )
    end

    def account_credential_service_type_for(base_runner)
      return base_runner.aider_required_api_service_type if base_runner.runner_key == "aider"
      return base_runner.pi_required_api_service_type if base_runner.runner_key == "pi"

      static = support_module.api_service_type_for(base_runner.runner_key)
      return static if static.present?

      nil
    end

    def seed_account_managed_model(base_runner, credential)
      return unless base_runner.runner_key == "pi"

      config = account_managed_runner_config(base_runner, credential)
      model_id = config.dig("pi", "model")
      api_provider = config.dig("pi", "api_provider")
      return if model_id.blank? || api_provider.blank?

      LlmModel.upsert_manual_catalog_entry(model_id: model_id, provider: api_provider)
    end

    def account_managed_runner_config(base_runner, credential)
      api_service_type = credential.provider_api_key&.api_service_type || account_credential_service_type_for(base_runner)

      case base_runner.runner_key
      when "aider"
        {
          "aider" => {
            "api_provider" => api_service_type,
            "model" => base_runner.aider_model_id
          }.compact
        }
      when "pi"
        config = {
          "pi" => {
            "api_provider" => api_service_type
          }
        }

        model = project.account.tenant_setting&.model_preference_for("pi").to_s.presence
        config["pi"]["model"] = model if model
        config
      else
        {}
      end
    end

    def runner_for_id(runner_id)
      self.class.selected_runner(project: project, runner_id: runner_id)
    end

    def runner_runnable?(runner)
      container_executable_runner_key?(runner.runner_key)
    end

    def agent_type_runnable?(agent_type)
      return false if agent_type.blank?

      AgentRun::AGENT_TYPES.include?(agent_type) &&
        container_executable_runner_key?(runner_key_for_agent_type(agent_type))
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
      enabled = first_enabled_for_owner(project.effective_owner)
      return [ enabled.id, agent_type_for_runner_key(enabled.runner_key) ] if enabled

      first_key = container_executable_runner_keys.first
      agent_type = first_key ? agent_type_for_runner_key(first_key) : "claude_code"
      [ nil, agent_type ]
    end

    def support_module
      RunnerSupport
    end

    def container_executable_runner_keys
      support_module.container_executable_runner_keys
    end

    def container_executable_runner_key?(runner_key)
      support_module.container_executable_runner_key?(runner_key)
    end

    def runner_key_for_agent_type(agent_type)
      support_module.runner_key_for_agent_type(agent_type)
    end

    def agent_type_for_runner_key(runner_key)
      support_module.agent_type_for(runner_key)
    end

    def first_enabled_for_owner(owner)
      return unless owner

      scope = owner.runners.kept_only.for_agent_runs.where(runner_key: container_executable_runner_keys).ordered
      scope = scope.where.not(id: exclude_runner_ids) if exclude_runner_ids.any?
      scope.first
    end

    def ensure_default_for(owner)
      key = container_executable_runner_keys.first
      return unless owner && key

      owner.runners.kept_only.find_or_create_by!(runner_key: key, auth_type: "subscription")
    rescue ActiveRecord::RecordNotUnique
      owner.runners.kept_only.find_by!(runner_key: key, auth_type: "subscription")
    end

    def runner_for_identifier(user, identifier)
      Runner.for_identifier(user, identifier)
    end
  end
end
