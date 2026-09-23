# frozen_string_literal: true

module Runners
  # @spec RUNNER-FALLBACK-007, RUNNER-FALLBACK-008, RUNNER-FALLBACK-009
  class ModelRecovery
    MAX_ATTEMPTS = 3
    Result = Struct.new(:model_id, :error, keyword_init: true) do
      def success? = model_id.present?
    end

    def initialize(agent_run:, runner:, tier:, executor: nil, deadline: nil)
      @agent_run, @runner, @tier = agent_run, runner, tier
      @executor = executor || Containers::HarnessExecutor.new(agent_run)
      @deadline = deadline
      @attempts = 0
      @tried = []
    end

    def call(rejected_model_id:)
      return failure("Runner does not support live model discovery") unless provider.respond_to?(:discover_available_models)
      return failure("Recovery requires a configured subscription runner") unless runner.subscription?

      evidence = VerifiedModels.new(runner)
      generation = evidence.reject!(rejected_model_id)
      return failure("Runner configuration changed during recovery") unless generation
      return failure("Replacement attempt budget exhausted") if @attempts >= MAX_ATTEMPTS

      discovery = provider.discover_available_models(env: auth_env, timeout: timeout(15))
      return failure("Model discovery unavailable: #{discovery.reason}") unless discovery.available?

      candidates = discovery.models.reject do |entry|
        id = entry.fetch(:id)
        @tried.include?(id) || evidence.rejected?(id) || !evidence.permitted?(id, project: agent_run.project, goal: agent_run.goal)
      end
      while candidates.any? && @attempts < MAX_ATTEMPTS
        candidate = select_candidate(candidates, discovery.recommended_model_id)
        model_id = candidate.fetch(:id)
        @tried << model_id
        @attempts += 1
        result = provider.smoke_test(timeout: timeout(60), provider_runtime: runtime(model_id))
        if result[:ok]
          unless evidence.remember!(tier: tier, model_id: model_id, generation: generation, project: agent_run.project, goal: agent_run.goal)
            return failure("Runner configuration or recovery changed during verification")
          end
          log("verified", rejected_model_id: rejected_model_id, model_id: model_id,
            model_tier: LlmModel.find_by(model_id: model_id)&.tier)
          return Result.new(model_id: model_id)
        end

        log("preflight_failed", model_id: model_id, error: result[:message])
        rejection = provider.class.classify_model_rejection(result[:message], configured_model: model_id)
        return failure(result[:message]) unless rejection

        generation = evidence.reject!(model_id)
        candidates.reject! { |entry| entry[:id] == model_id }
      end
      failure("No verified policy-permitted replacement after #{@attempts} attempts")
    rescue AgentHarness::Error, Containers::Provision::Error => e
      failure(e.message)
    end

    private

    attr_reader :agent_run, :runner, :tier, :executor

    def provider
      @provider ||= begin
        key = RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym
        config = AgentHarness.build_config(key)
        config.externally_sandboxed = true
        AgentHarness.provider_class(key).new(config: config, executor: executor)
      end
    end

    def auth_env
      RunnerSupport.subscription_auth_unset_vars_for(runner.runner_key).index_with { nil }
    end

    def runtime(model_id)
      AgentHarness::ProviderRuntime.new(model: model_id, unset_env: auth_env.keys)
    end

    def select_candidate(entries, default_id)
      catalog = LlmModel.where(model_id: entries.map { |entry| entry[:id] }).index_by(&:model_id)
      models = entries.map do |entry|
        catalog[entry[:id]] || LlmModel.new(model_id: entry[:id], display_name: entry[:display_name] || entry[:id],
          provider: DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER.fetch(runner.runner_key))
      end
      same_tier = models.select { |model| model.tier == tier }
      pool = same_tier.presence || models
      eligible_entries = same_tier.any? ? entries.select { |entry| same_tier.any? { |model| model.model_id == entry[:id] } } : entries
      selected = Models::MetaAgentSelector.new(agent_run: agent_run, candidates: pool, timeout: timeout(15)).call if pool.any?
      selected_id = selected&.dig(:model)&.model_id
      eligible_entries.find { |entry| entry[:id] == selected_id } ||
        eligible_entries.find { |entry| entry[:id] == default_id } || eligible_entries.first
    end

    def timeout(limit)
      remaining = @deadline ? (@deadline - Time.current).floor : limit
      raise AgentHarness::TimeoutError, "Run execution budget exhausted during model recovery" if remaining <= 0

      [ limit, remaining ].min
    end

    def failure(message)
      log("unrecovered", error: message)
      Result.new(error: message)
    end

    def log(outcome, **details)
      details[:error] = AgentRun::ErrorMessageSanitizer.call(text: details[:error]) if details[:error]
      agent_run.log!("system", "Model/auth recovery #{outcome} for #{runner.display_name}",
        metadata: { type: "model_auth_recovery", outcome: outcome, runner_id: runner.id,
                    auth_type: runner.auth_type, requested_tier: tier, **details }.compact)
    end
  end
end
