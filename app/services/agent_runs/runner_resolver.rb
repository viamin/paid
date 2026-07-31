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
    #
    # +effective_runner+ is the runner_key used to look up tenant-level model
    # preferences (see TenantSetting#model_preference_for, which is keyed by
    # runner_key). Call sites that already have an AgentRun should pass
    # `agent_run.effective_runner` so the tenant branch in
    # +override_model_id_for+ matches the same lookup used by
    # Models::Select#tenant_model_preference_result. Call sites that resolve
    # a runner for the first time (before any AgentRun exists) may leave this
    # nil; in that case the tenant-preference branch is skipped because no
    # runner_key has been chosen yet.
    def initialize(project:, goal:, requested_agent_type: nil, requested_runner_id: nil, respect_requested: true,
                   exclude_runner_ids: [], effective_runner: nil, logger: nil)
      @project = project
      @goal = goal
      @requested_agent_type = requested_agent_type
      @requested_runner_id = requested_runner_id
      @respect_requested = respect_requested
      @exclude_runner_ids = Array(exclude_runner_ids)
      @effective_runner = effective_runner
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

    attr_reader :project, :goal, :requested_agent_type, :requested_runner_id, :respect_requested, :exclude_runner_ids,
                :effective_runner, :logger

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

      # RDR-040: when the project has a model override (required / preferred /
      # tenant), the base runner and the fallback must be runners that can
      # actually execute that model — otherwise Models::Select will
      # short-circuit to a no-selection outcome and waste a queue cycle
      # discovering the mismatch. Prefer a compatible runner over the
      # setting-derived base; fall through to the existing chain when no
      # override is configured or no compatible runner is available.
      override_model_id = override_model_id_for(project)
      compat_runner = compatibility_aware_fallback(owner, override_model_id: override_model_id)
      if compat_runner && (base_runner.nil? || !runner_compatible_with_model?(base_runner, override_model_id))
        # Override the setting-derived base with a compatible runner so the
        # run lands on a runner that can actually execute the override
        # model. Without this, a project-required Anthropic model would
        # still be pinned to the default Codex runner (which can't run it)
        # and Models::Select would short-circuit to a no-selection.
        base_runner = compat_runner
      end
      fallback_runner = compat_runner ||
        Runner.first_enabled_for_owner(owner) ||
        Runner.ensure_default_for(owner)

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

    # RDR-040: When the project has a model override, scan the runnable
    # runner pool and return the first runner that is compatible with the
    # override model. The pool is sorted by +ordered+ (alphabetical by
    # runner_key, then auth_type, name, id). Returns nil when no override
    # is set or when no compatible runner is in the pool, in which case
    # the caller falls back to the existing chain. Always excludes runners
    # that already failed preflight this dequeue pass.
    def compatibility_aware_fallback(owner, override_model_id: nil)
      return nil unless owner

      override_model_id ||= override_model_id_for(project)
      return nil if override_model_id.blank?

      scope = owner.runners.kept_only.for_agent_runs
        .where(runner_key: container_executable_runner_keys)
        .where.not(id: exclude_runner_ids)
        .ordered

      matched = nil
      scope.each do |candidate|
        if runner_compatible_with_model?(candidate, override_model_id)
          matched = candidate
          break
        end
      end

      # When no runner in the pool is compatible with the override, log so
      # operators can see the eventual no-selection outcome traceable to a
      # missing compatible runner — not to a generic "no fallback".
      if matched.nil?
        candidate_keys = scope.pluck(:runner_key)
        if candidate_keys.any?
          Rails.logger.warn(
            message: "agent_execution.no_compatible_runner_for_override",
            project_id: project.id,
            goal: goal,
            override_model_id: override_model_id,
            candidate_runner_keys: candidate_keys
          )
        end
      end

      matched
    end

    # RDR-040: returns the model_id implied by the project's preference chain
    # (required > first preferred > tenant preference for the effective
    # runner), or nil when no preference is configured. Used to inform the
    # runner fallback chain so we don't pick a runner that the model can't
    # run on. The tenant branch uses +effective_runner+ as the lookup key to
    # match TenantSetting#model_preference_for (keyed by runner_key, not
    # goal); when no +effective_runner+ has been resolved yet (e.g. before
    # any AgentRun exists) the tenant branch is skipped because no runner
    # has been chosen to scope the preference to.
    def override_model_id_for(project)
      prefs = project.model_preferences || {}
      explicit = prefs["required_model_id"].presence
      return explicit if explicit

      preferred = Array(prefs["preferred_model_ids"]).first
      return preferred if preferred

      return nil if effective_runner.blank?

      tenant = project.account.tenant_setting&.model_preference_for(effective_runner)
      tenant.presence
    end

    def runner_compatible_with_model?(runner, model_id)
      return true if runner.blank?
      return true if model_id.blank?

      result = Runners::ModelCompatibility.call(
        runner_key: runner.runner_key,
        model_id: model_id,
        auth_type: runner.auth_type,
        provider_runtime: runner.agent_harness_runner_runtime
      )
      !result.unsupported?
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

    # @spec RUNNER-SCHED-005
    def runner_runnable?(runner)
      return false if runner.blocked_by_time_window?
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
