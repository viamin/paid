# frozen_string_literal: true

module Providers
  # Sends a lightweight test prompt to a provider's agent to verify
  # installation, authentication, and responsiveness.
  #
  # @example
  #   result = Providers::TestAgent.call(provider: provider)
  #   result.success? # => true
  class TestAgent
    UnsupportedProviderError = Class.new(StandardError)
    NotContainerExecutableError = Class.new(StandardError)

    PROMPT = "Respond with exactly: PING OK"
    EXPECTED_OUTPUT = "PING OK"
    TIMEOUT = 30

    attr_reader :provider

    def initialize(provider:)
      @provider = provider
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      response = execute_test
      process_response(response)
    rescue NotContainerExecutableError
      Result.new(success: false, error_type: :installation,
        message: "Provider #{provider.provider_key} CLI is not installed in the agent container")
    rescue UnsupportedProviderError
      Result.new(success: false, error_type: :unexpected,
        message: "Provider #{provider.provider_key} is not recognized by the agent harness")
    rescue AgentHarness::AuthenticationError => e
      Result.new(success: false, error_type: :authentication, message: e.message)
    rescue AgentHarness::TimeoutError => e
      Result.new(success: false, error_type: :timeout, message: e.message)
    rescue AgentHarness::Error => e
      Result.new(success: false, error_type: :connection, message: e.message)
    rescue StandardError => e
      Rails.logger.error(
        message: "providers.test_agent.unexpected_error",
        provider_key: provider&.provider_key,
        error_class: e.class.name,
        error_message: e.message
      )
      Result.new(success: false, error_type: :unexpected, message: e.message)
    end

    private

    def validate!
      unless ProviderSupport.supported_provider_key?(provider.provider_key)
        raise UnsupportedProviderError, "Unknown provider: #{provider.provider_key}"
      end

      unless ProviderSupport.container_executable_provider_key?(provider.provider_key)
        raise NotContainerExecutableError,
          "Provider #{provider.provider_key} is not installed in the agent container"
      end
    end

    def execute_test
      harness_key = ProviderSupport.harness_provider_key_for(provider.provider_key)

      AgentHarness.send_message(
        PROMPT,
        provider: harness_key.to_sym,
        timeout: TIMEOUT,
        dangerous_mode: false
      )
    end

    def process_response(response)
      unless response.success?
        return Result.new(
          success: false,
          error_type: :unexpected,
          message: response.error.presence || "Agent exited with code #{response.exit_code}"
        )
      end

      if response.output.to_s.strip == EXPECTED_OUTPUT
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      else
        Result.new(
          success: false,
          error_type: :unexpected,
          message: "Agent responded but output did not match expected ping"
        )
      end
    end

    class Result
      attr_reader :error_type, :message

      def initialize(success:, error_type: nil, message: nil)
        @success = success
        @error_type = error_type
        @message = message
      end

      def success?
        @success
      end
    end
  end
end
