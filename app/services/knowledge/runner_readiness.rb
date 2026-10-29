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
      return text_runner_readiness if operation == :chat
      return unsupported unless supported?

      credential
    end

    private

    attr_reader :account, :owner, :operation, :runner

    def text_runner_readiness
      selected = Runner.for_identifier(owner, runner)
      return unsupported unless selected&.enabled_for_chat? && !selected.discarded?

      if selected.subscription?
        key = RunnerSupport.harness_runner_key_for(selected.runner_key).to_sym
        driver = AgentHarness.provider_class(key).new(config: AgentHarness.build_config(key))
        managed = owner.account.runner_credentials.for_runner(selected.runner_key).where(revoked_at: nil).exists?
        status = managed || !driver.supports_tool_control? ? "isolation_required" : "ready"
        return Result.new(status: status, credential_source: "subscription", credential_service: "subscription",
          credential_name: "Configured subscription", validated_with_provider: false)
      end
      return missing_credential(selected.required_api_service_type) unless selected.provider_api_key || selected.active_integration_credential?

      Result.new(status: "ready", credential_source: "runner_credential", credential_service: selected.required_api_service_type,
        credential_name: selected.provider_api_key&.name || "Configured integration credential", validated_with_provider: false)
    end

    def supported?
      supported_runners.include?(runner) && (operation == :embedding || AnalysisRunner.supported_provider?(runner))
    end

    def supported_runners
      operation == :embedding ? UserSetting::KB_EMBEDDING_RUNNERS : UserSetting::KB_CHAT_RUNNERS
    end

    def credential
      selection = CredentialSelection.call(owner:, operation:, runner:, credentials: provider_api_keys)
      return ready(selection) if selection.status == :ready
      return invalid_credential(selection) if selection.status == :invalid_credential
      return unsupported if selection.status == :unsupported_transport

      missing_credential(selection.service_type)
    end

    def provider_api_keys
      return credential_availability.fetch(:provider_api_keys) if credential_availability

      owner.provider_api_keys.to_a
    end

    attr_reader :credential_availability

    def ready(selection)
      Result.new(
        status: "ready",
        credential_source: selection.source.to_s,
        credential_service: selection.service_type,
        credential_name: selection.api_key_record&.name || "Platform credential",
        validated_with_provider: false
      )
    end

    def invalid_credential(selection)
      Result.new(
        status: "invalid_credential",
        credential_source: selection.source.to_s,
        credential_service: selection.service_type,
        credential_name: nil,
        validated_with_provider: false
      )
    end

    def missing_credential(service = nil)
      Result.new(status: "missing_credential", credential_source: nil, credential_service: service, credential_name: nil, validated_with_provider: false)
    end

    def unsupported
      Result.new(status: "unsupported_transport", credential_source: nil, credential_service: nil, credential_name: nil, validated_with_provider: false)
    end
  end
end
