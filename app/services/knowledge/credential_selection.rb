# frozen_string_literal: true

module Knowledge
  # Resolves the explicitly selected credential for a knowledge operation.
  # @spec KNOWLEDGE-CREDENTIAL-001
  class CredentialSelection
    Result = Data.define(:status, :source, :service_type, :api_key_record, :api_key)

    def self.call(...)
      new(...).call
    end

    def initialize(owner:, operation:, runner:, credentials: nil)
      @owner = owner
      @operation = operation.to_sym
      @runner = runner
      @credentials = credentials
    end

    def call
      return unsupported unless service_type

      selected_credential || platform_credential || missing
    end

    private

    attr_reader :owner, :operation, :runner

    def selected_credential
      selected_id = user_setting&.public_send("kb_#{operation}_provider_api_key_id")
      return legacy_credential unless selected_id

      credential = available_credentials.find { |candidate| candidate.id == selected_id }
      return invalid unless credential
      return invalid unless credential.api_service_type == service_type

      ready(source: :saved_key, api_key_record: credential, api_key: credential.api_key)
    end

    # Existing installations predate explicit bindings. Keep their established
    # behavior until a user selects a key; a selected binding always wins.
    def legacy_credential
      credential = available_credentials
        .select { |candidate| candidate.api_service_type == service_type }
        .max_by { |candidate| [ candidate.created_at, candidate.id ] }
      return unless credential

      ready(source: :owner_api_key, api_key_record: credential, api_key: credential.api_key)
    end

    def platform_credential
      key = platform_api_key
      return unless key

      ready(source: :platform_fallback, api_key: key)
    end

    def platform_api_key
      return unless %w[openai anthropic].include?(service_type)
      return unless operation == :chat || runner == "openai"

      Rails.application.credentials.dig(:llm, :"#{service_type}_api_key").presence ||
        ENV["#{service_type.upcase}_API_KEY"].presence
    end

    def service_type
      @service_type ||= if operation == :embedding
        Runner::DIRECT_OUTBOUND_API_PROVIDERS.dig(runner, :service_type)
      else
        RunnerSupport.api_service_type_for(runner)
      end
    end

    def user_setting
      owner&.settings
    end

    def available_credentials
      return @credentials if defined?(@credentials) && @credentials

      owner&.provider_api_keys&.to_a || []
    end

    def ready(source:, api_key_record: nil, api_key:)
      Result.new(status: :ready, source:, service_type:, api_key_record:, api_key:)
    end

    def missing
      Result.new(status: :missing_credential, source: nil, service_type:, api_key_record: nil, api_key: nil)
    end

    def invalid
      Result.new(status: :invalid_credential, source: :saved_key, service_type:, api_key_record: nil, api_key: nil)
    end

    def unsupported
      Result.new(status: :unsupported_transport, source: nil, service_type: nil, api_key_record: nil, api_key: nil)
    end
  end
end
