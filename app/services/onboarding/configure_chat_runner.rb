# frozen_string_literal: true

module Onboarding
  # Creates the minimum credential, runner, and conversation needed to start
  # chat-led onboarding. All records are committed together so a failed chat
  # bootstrap leaves the user on the API-key step with nothing partial saved.
  # @spec ONBOARD-CHAT-002 ONBOARD-CHAT-003
  class ConfigureChatRunner
    Result = Data.define(:provider_api_key, :runner, :chat_session)
    WELCOME_TITLE = "Welcome to Paid — let's set you up"

    def self.call(...)
      new(...).call
    end

    def initialize(account:, user:, api_service_type:, api_key:)
      @account = account
      @user = user
      @api_service_type = api_service_type.to_s
      @api_key = api_key
    end

    def call
      ActiveRecord::Base.transaction do
        provider_api_key = create_provider_api_key
        runner = create_runner(provider_api_key)
        chat_session = create_chat_session(runner)
        complete_onboarding_step(provider_api_key, runner)
        Result.new(provider_api_key, runner, chat_session)
      end
    end

    private

    attr_reader :account, :user, :api_service_type, :api_key

    def create_provider_api_key
      user.provider_api_keys.create!(
        name: "#{RunnerSupport.api_service_type_label(api_service_type)} onboarding key",
        api_service_type: api_service_type,
        api_key: api_key
      )
    end

    def create_runner(provider_api_key)
      user.runners.create!(
        runner_key: runner_key,
        name: "#{RunnerSupport.api_service_type_label(api_service_type)} onboarding chat",
        auth_type: "api_key",
        provider_api_key: provider_api_key,
        enabled_for_chat: true,
        enabled_for_agent_runs: RunnerSupport.addable_runner_key?(runner_key),
        enabled_for_fallback: false,
        fallback_role: "standard",
        config: runner_config
      )
    end

    def create_chat_session(runner)
      ChatSessions::Create.call(
        account: account,
        user: user,
        runner_id: runner.id,
        title: WELCOME_TITLE,
        metadata: { "onboarding" => true }
      )
    end

    def complete_onboarding_step(provider_api_key, runner)
      Onboarding::CompleteStep.call(
        account: account,
        step: "chat_api_key",
        metadata: {
          provider_api_key_id: provider_api_key.id,
          runner_id: runner.id,
          api_service_type: api_service_type
        }
      )
    end

    def runner_key
      @runner_key ||= fixed_runner_key || direct_outbound_runner_key
    end

    def fixed_runner_key
      RunnerSupport::RUNNER_API_SERVICE_TYPE.key(api_service_type)
    end

    def direct_outbound_runner_key
      Runner::DIRECT_OUTBOUND_FREE_POLICY_RUNNER_KEYS.find { |key| supported_by_runner?(key) } ||
        raise(ArgumentError, "No chat runner supports #{api_service_type.inspect}")
    end

    def supported_by_runner?(key)
      case key
      when "opencode", "kilocode"
        Runner::DIRECT_OUTBOUND_SERVICE_TYPES.include?(api_service_type)
      when "pi", "omp"
        Runner::PI_API_PROVIDERS.values.any? { |provider| provider[:service_type] == api_service_type }
      end
    end

    def runner_config
      return {} if fixed_runner_key

      { runner_key => runner_options }
    end

    def runner_options
      { "api_provider" => Runner.api_service_type_to_provider_key(api_service_type) }.merge(model_options)
    end

    def model_options
      return { "model_policy" => "free" } if api_service_type == Runner::OPENROUTER_FREE_MODEL_PROVIDER
      return {} unless %w[opencode kilocode].include?(runner_key)

      { "model" => chat_model_id }
    end

    def chat_model_id
      LlmModel.active.by_provider(api_service_type).by_capability.first&.model_id ||
        raise(ArgumentError, "No chat model is available for #{RunnerSupport.api_service_type_label(api_service_type)}")
    end
  end
end
