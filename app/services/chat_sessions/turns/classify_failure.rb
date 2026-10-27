# frozen_string_literal: true

module ChatSessions
  module Turns
    # Maps an exception onto the durable failure class a chat turn records.
    #
    # The class is what a later stall classification reads, so it has to be a
    # structural property of the error rather than a judgement about intent.
    module ClassifyFailure
      # Errors that no amount of retrying fixes: the credentials, the
      # configuration, or the provider selection are wrong.
      NON_RETRYABLE = [
        AgentHarness::AuthenticationError,
        AgentHarness::AuthorizationError,
        AgentHarness::ConfigurationError,
        AgentHarness::ProviderNotFoundError
      ].freeze

      module_function

      def for(error)
        case error
        when AgentHarness::TimeoutError then "provider_timeout"
        when AgentHarness::RateLimitError then "provider_rate_limit"
        when ChatSessions::TokenLimitExceededError then "token_limit"
        when *NON_RETRYABLE then "configuration_error"
        when AgentHarness::Error then "infrastructure_failure"
        else "unknown_error"
        end
      end
    end
  end
end
