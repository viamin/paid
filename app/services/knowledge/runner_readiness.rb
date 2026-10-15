# frozen_string_literal: true

module Knowledge
  # Resolves configuration readiness without materializing a secret or calling
  # an upstream provider. The dashboard consumes this same local resolution
  # information that knowledge execution uses to select its credential source.
  # @spec KNOWLEDGE-DASHBOARD-001
  class RunnerReadiness
    Result = Data.define(:status, :credential_source, :credential_service, :credential_name, :validated_with_provider)

    def self.call(...)
      new(...).call
    end

    def initialize(owner:, operation:, runner:, credential_availability: nil)
      @owner = owner
      @operation = operation.to_sym
      @runner = runner
      @credential_availability = credential_availability
    end

    def call
      return unsupported unless supported?

      service_type = credential_service_type
      return missing_credential unless service_type

      credential(service_type) || missing_credential(service_type)
    end

    private

    attr_reader :account, :owner, :operation, :runner

    def supported?
      supported_runners.include?(runner) && (operation == :embedding || AnalysisRunner.supported_provider?(runner))
    end

    def supported_runners
      operation == :embedding ? UserSetting::KB_EMBEDDING_RUNNERS : UserSetting::KB_CHAT_RUNNERS
    end

    def credential(service_type)
      owner_api_key_credential(service_type) || platform_credential(service_type)
    end

    def credential_service_type
      return Runner::DIRECT_OUTBOUND_API_PROVIDERS.dig(runner, :service_type) if operation == :embedding

      RunnerSupport.api_service_type_for(runner)
    end

    def owner_api_key_credential(service_type)
      api_key = provider_api_keys
        .select { |candidate| candidate.api_service_type == service_type }
        .max_by { |candidate| [ candidate.created_at, candidate.id ] }
      return unless api_key

      ready(source: "owner_api_key", service: service_type, name: api_key.name)
    end

    def provider_api_keys
      return credential_availability.fetch(:provider_api_keys) if credential_availability

      owner.provider_api_keys.to_a
    end

    attr_reader :credential_availability

    def platform_credential(service_type)
      return platform_openai_credential if service_type == "openai"

      platform_anthropic_credential if service_type == "anthropic"
    end

    def platform_openai_credential
      return unless (operation == :chat || runner == "openai") && platform_openai_api_key.present?

      ready(source: "platform_fallback", service: "openai", name: "Platform credential")
    end

    def platform_anthropic_credential
      return unless platform_anthropic_api_key.present?

      ready(source: "platform_fallback", service: "anthropic", name: "Platform credential")
    end

    def platform_openai_api_key
      Rails.application.credentials.dig(:llm, :openai_api_key).presence || ENV["OPENAI_API_KEY"].presence
    end

    def platform_anthropic_api_key
      Rails.application.credentials.dig(:llm, :anthropic_api_key).presence || ENV["ANTHROPIC_API_KEY"].presence
    end

    def ready(source:, service:, name:)
      Result.new(status: "ready", credential_source: source, credential_service: service, credential_name: name, validated_with_provider: false)
    end

    def missing_credential(service = nil)
      Result.new(status: "missing_credential", credential_source: nil, credential_service: service, credential_name: nil, validated_with_provider: false)
    end

    def unsupported
      Result.new(status: "unsupported_transport", credential_source: nil, credential_service: nil, credential_name: nil, validated_with_provider: false)
    end
  end
end
