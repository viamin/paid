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

    def initialize(owner:, operation:, runner:, credential_availability: nil)
      @owner = owner
      @operation = operation.to_sym
      @runner = runner
      @credential_availability = credential_availability
    end

    def call
      return unsupported unless supported?

      credential || missing_credential
    end

    private

    attr_reader :account, :owner, :operation, :runner

    def supported?
      supported_runners.include?(runner) && (operation == :embedding || AnalysisRunner.supported_provider?(runner))
    end

    def supported_runners
      operation == :embedding ? UserSetting::KB_EMBEDDING_RUNNERS : UserSetting::KB_CHAT_RUNNERS
    end

    def credential
      return embedding_credential if operation == :embedding

      selected_credential
    end

    def embedding_credential
      selected_credential
    end

    def selected_credential
      selection = CredentialSelection.call(owner:, operation:, runner:, credentials: provider_api_keys)
      return unless selection.status == :ready

      ready(source: selection.source.to_s, service: selection.service_type)
    end

    def provider_api_keys
      return credential_availability.fetch(:provider_api_keys) if credential_availability

      owner.provider_api_keys.to_a
    end

    attr_reader :credential_availability

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
