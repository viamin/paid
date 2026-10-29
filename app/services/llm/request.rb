# frozen_string_literal: true

module Llm
  # Routes application text through owned, configured runners and credentials.
  class Request
    def self.call(...) = new(...).call

    def initialize(prompt:, timeout:, agent_run: nil, project: nil, account: nil, user: nil, model: nil, runner: nil, harness: AgentHarness)
      @runner_identifier = runner
      @model = model
      @harness = harness
      @agent_run = agent_run
      @project = agent_run&.project || project
      @account = @project&.account || account || user&.account || Current.account
      @user = @project&.effective_owner || user || account&.fallback_owner || Current.user || @account&.fallback_owner
      @prompt = prompt
      @timeout = timeout
    end

    def call # @spec LLM-ROUTING-001 LLM-ROUTING-002 LLM-ROUTING-003 LLM-ROUTING-005 MODEL-POLICY-015 MODEL-POLICY-016 MODEL-POLICY-024 PARTIAL-CLOSEOUT-031
      unless @user && (!@account || @user.account_id == @account.id)
        raise AgentHarness::ConfigurationError, "No owning user for this LLM request"
      end
      runners = if @runner_identifier
        [ Runner.for_identifier(@user, @runner_identifier) ].compact
      elsif agent_run&.effective_runner_record
        [ agent_run.effective_runner_record ]
      else
        selected_runners
      end
      raise AgentHarness::ConfigurationError, "No eligible configured runner for this LLM request" if runners.empty?

      @required_zdr = @project&.restricted? || agent_run&.external_metadata.to_h["zdr_required"] == true ||
        runners.first.zero_data_retention?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      response = error = nil
      eligible_route = false
      runners.each do |runner|
        candidate_required_zdr = @required_zdr || runner.zero_data_retention?
        policy = runner.effective_privacy_policy(project: @project, required_zdr: candidate_required_zdr)
        next unless policy.eligible

        eligible_route = true
        @required_zdr = candidate_required_zdr
        remaining = (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).ceil
        raise AgentHarness::TimeoutError, "LLM request timeout exhausted" if remaining <= 0

        response = perform_request(runner, timeout: remaining)
        error = nil
        return response if !response.respond_to?(:success?) || response.success?
      rescue AgentHarness::Error => failure
        Rails.logger.warn(message: "llm.request_runner_failed", runner_id: runner.id,
          project_id: @project&.id, error_class: failure.class.name)
        error = failure
      end
      raise error if error
      unless eligible_route
        raise AgentHarness::ConfigurationError,
          "No eligible configured runner can satisfy the required zero data retention policy"
      end

      response
    end

    private

    def perform_request(runner, timeout:)
      unless runner && !runner.discarded? && runner.user_id == @user&.id && permitted_usage?(runner)
        raise AgentHarness::ConfigurationError, "No eligible configured runner for this run's LLM request"
      end
      key = RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym
      config = AgentHarness.build_config(key)
      config.externally_sandboxed = isolated?
      executor = Containers::DeadlineExecutor.new(Containers::HarnessExecutor.new(agent_run)) if isolated?
      provider = AgentHarness.provider_class(key).new(config: config, executor: executor)
      runtime = runtime_for(runner)
      validate_model_policy!(runner, @policy_model_id || runtime.model)
      if !isolated? && runner.api_key?
        if isolated_data_routing_required?(runner)
          raise AgentHarness::ConfigurationError,
            "The selected runner requires isolated execution to enforce zero data retention"
        end

        api_runtime = AgentHarness::ProviderRuntime.new(model: @policy_model_id || runtime.model, base_url: runtime.base_url)
        return ApiRequest.call(runner: runner, runtime: api_runtime, prompt: @prompt, timeout: timeout)
      end
      runtime = host_subscription_runtime(runner, provider, runtime) unless isolated?
      unless isolated? || provider.supports_tool_control?
        raise AgentHarness::ConfigurationError, "The selected runner requires an isolated environment or API credentials for text requests"
      end
      options = { timeout: timeout, tools: :none, dangerous_mode: false, mcp_servers: [], provider_runtime: runtime }
      return provider.send_message(prompt: @prompt, **options) if isolated?

      @harness.conductor.execute_direct(@prompt, provider: key, model: runtime.model, **options, externally_sandboxed: false)
    end

    attr_reader :agent_run

    def validate_model_policy!(runner, model_id)
      return unless @project

      model = LlmModel.find_by(model_id: model_id)
      provider = model&.provider || Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner.runner_key] || runner.direct_outbound_llm_model_provider
      preferences = @project.model_preferences
      required = preferences["required_model_id"]
      if model&.operator_active_override == false || Array(preferences["excluded_model_ids"]).include?(model_id) ||
          (required.present? && required != model_id) ||
          (@project.llm_provider_routing_restricted? && (provider.blank? || !@project.llm_provider_allowed?(provider))) ||
          !Runners::VerifiedModels.within_tier_bounds?(model, preferences, agent_run&.goal)
        raise AgentHarness::ConfigurationError, "Selected model violates project model policy"
      end
    end

    def permitted_usage?(runner)
      agent_run&.effective_runner_record ? runner.enabled_for_agent_runs? : runner.enabled_for_chat?
    end

    def isolated_data_routing_required?(runner)
      runner.zero_data_retention_enforced? ||
        (@project&.restricted? && runner.required_api_service_type == Runner::OPENROUTER_FREE_MODEL_PROVIDER)
    end

    def selected_runners
      return unless @user && (!@account || @user.account_id == @account.id)

      RunnerSelection.available_candidates(user: @user)
    end

    def isolated?
      agent_run && (agent_run.container_id.present? || agent_run.runner_handle.present?)
    end

    def host_subscription_runtime(runner, provider, runtime)
      if @account&.runner_credentials&.for_runner(runner.runner_key)&.where(revoked_at: nil)&.exists?
        raise AgentHarness::ConfigurationError, "Managed subscription credentials require an isolated execution environment"
      end

      AgentHarness::ProviderRuntime.new(model: runtime.model, api_provider: runtime.api_provider,
        base_url: runtime.base_url, env: runtime.env, unset_env: runtime.unset_env | provider.subscription_unset_vars,
        flags: runtime.flags, metadata: runtime.metadata)
    end

    def runtime_for(runner)
      tier = agent_run&.model_selection&.tier.presence || "mid"
      resolved = Runners::ResolveTierModel.call(runner: runner, tier: tier,
        user: runner.user, project: @project, goal: agent_run&.goal)
      if @model.present?
        compatible = Runners::ModelCompatibility.call(runner_key: runner.runner_key, model_id: @model, auth_type: runner.auth_type)
        unless !compatible.unsupported? && Runners::VerifiedModels.new(runner).permitted?(@model, project: @project, goal: agent_run&.goal)
          raise AgentHarness::ConfigurationError, "Requested model is not permitted for the selected runner"
        end
        resolved = Runners::ResolveTierModel::Result.new(model_id: @model)
      end
      configured = runner.agent_harness_runner_runtime(project: @project, required_zdr: @required_zdr) unless runner.free_model_policy?
      if configured && resolved.failure? && resolved.error_type == :missing_model
        @policy_model_id = runner.direct_outbound_model_id.presence || configured.model
        return configured
      end
      raise AgentHarness::ConfigurationError, "No permitted model for this LLM request: #{resolved.error}" if resolved.failure?
      @policy_model_id = resolved.model_id
      if runner.free_model_policy?
        return runner.free_model_policy_runner_runtime(
          project: @project, model_id: resolved.model_id, required_zdr: @required_zdr
        )
      end

      AgentHarness::ProviderRuntime.new(
        model: runner.qualified_model_for(resolved.model_id),
        api_provider: configured&.api_provider, base_url: configured&.base_url,
        env: configured&.env || {}, unset_env: configured&.unset_env || [],
        flags: configured&.flags || [], metadata: configured&.metadata || {}
      )
    end
  end
end
