# frozen_string_literal: true

module Knowledge
  # Resolves configuration readiness without materializing a secret or calling
  # an upstream provider. The dashboard consumes this same local resolution
  # information that knowledge execution uses to select its credential source.
  # @spec KNOWLEDGE-DASHBOARD-001
  class RunnerReadiness
    Result = Data.define(:status, :credential_source, :credential_service, :validated_with_provider)

    def self.call(...)
      new(...).call
    end

    def initialize(account:, owner:, operation:, runner:)
      @account = account
      @owner = owner
      @operation = operation.to_sym
      @runner = runner
    end

    def call
      return unsupported unless supported?

      credential || missing_credential
    end

    private

    attr_reader :account, :owner, :operation, :runner

    def supported?
      supported_runners.include?(runner)
    end

    def supported_runners
      operation == :embedding ? UserSetting::KB_EMBEDDING_RUNNERS : UserSetting::KB_CHAT_RUNNERS
    end

    def credential
      return embedding_credential if operation == :embedding

      managed_runner_credential || runner_api_key_credential
    end

    def embedding_credential
      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS[runner]
      return unless config

      owner_api_key_credential(config.fetch(:service_type)) || platform_openai_credential
    end

    def managed_runner_credential
      return unless account.runner_credentials.active.for_runner(runner).exists?

      ready(source: "managed_runner_credential", service: Runner.display_name_for(runner))
    end

    def runner_api_key_credential
      api_key = owner.provider_api_keys.order(created_at: :desc, id: :desc).find do |candidate|
        candidate.compatible_with?(runner)
      end
      return unless api_key

      ready(source: "owner_api_key", service: api_key.api_service_type)
    end

    def owner_api_key_credential(service_type)
      return unless owner.provider_api_keys.for_api_service_type(service_type).exists?

      ready(source: "owner_api_key", service: service_type)
    end

    def platform_openai_credential
      return unless runner == "openai" && platform_openai_api_key.present?

      ready(source: "platform_fallback", service: "openai")
    end

    def platform_openai_api_key
      Rails.application.credentials.dig(:llm, :openai_api_key).presence || ENV["OPENAI_API_KEY"].presence
    end

    def ready(source:, service:)
      Result.new(status: "ready", credential_source: source, credential_service: service, validated_with_provider: false)
    end

    def missing_credential
      Result.new(status: "missing_credential", credential_source: nil, credential_service: nil, validated_with_provider: false)
    end

    def unsupported
      Result.new(status: "unsupported_transport", credential_source: nil, credential_service: nil, validated_with_provider: false)
    end
  end
end
