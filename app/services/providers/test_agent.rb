# frozen_string_literal: true

module Providers
  # Sends a lightweight test prompt to a provider's agent to verify
  # installation, authentication, and responsiveness.
  #
  # @example
  #   result = Providers::TestAgent.call(provider: provider)
  #   result.success? # => true
  class TestAgent
    PROMPT = "Respond with exactly: PING OK"
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
    rescue AgentHarness::AuthenticationError => e
      Result.new(success: false, error_type: :authentication, message: e.message)
    rescue AgentHarness::TimeoutError => e
      Result.new(success: false, error_type: :timeout, message: e.message)
    rescue AgentHarness::Error => e
      Result.new(success: false, error_type: :connection, message: e.message)
    rescue StandardError => e
      Result.new(success: false, error_type: :unexpected, message: e.message)
    end

    private

    def validate!
      harness_key = ProviderSupport.harness_provider_key_for(provider.provider_key)
      raise AgentHarness::Error, "Unknown provider: #{provider.provider_key}" unless harness_key
    end

    def execute_test
      harness_key = ProviderSupport.harness_provider_key_for(provider.provider_key)

      AgentHarness.send_message(
        PROMPT,
        provider: harness_key.to_sym,
        timeout: TIMEOUT
      )
    end

    def process_response(response)
      if response.success?
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      else
        Result.new(
          success: false,
          error_type: :connection,
          message: response.error || "Agent exited with code #{response.exit_code}"
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
