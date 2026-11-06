# frozen_string_literal: true

module Llm
  # Classifies partial-closeout assessment failures into bounded categories so
  # post-processing can retry transient transport problems and park on the
  # problems an operator has to fix first.
  #
  # Categories never carry provider payloads or credentials: they name the
  # failure mode so a retry policy and a durable recovery record can act on it
  # without persisting response content.
  # @spec PARTIAL-CLOSEOUT-042
  class PartialCloseoutFailure
    TIMEOUT = "timeout"
    TRANSPORT_ERROR = "transport_error"
    UNSUCCESSFUL_RESPONSE = "unsuccessful_response"
    INVALID_JSON = "invalid_json"
    INVALID_ASSESSMENT = "invalid_assessment"
    AUTHENTICATION_UNAVAILABLE = "authentication_unavailable"
    CONFIGURATION_ERROR = "configuration_error"
    BUDGET_EXHAUSTED = "budget_exhausted"
    EXECUTION_PAUSED = "execution_paused"

    # Transient categories: the runner may answer the same request later, so
    # the assessment is retried with backoff before the run parks.
    RETRYABLE_CATEGORIES = [
      TIMEOUT, TRANSPORT_ERROR, UNSUCCESSFUL_RESPONSE, INVALID_JSON, INVALID_ASSESSMENT
    ].freeze

    # Categories a human has to resolve before a retry can succeed.
    OPERATOR_CATEGORIES = [
      AUTHENTICATION_UNAVAILABLE, CONFIGURATION_ERROR, BUDGET_EXHAUSTED, EXECUTION_PAUSED
    ].freeze

    RECOVERY_ACTION = "retry_assessment"
    OPERATOR_ACTION = "operator_action_required"

    def self.category_for(error)
      return error.category if error.is_a?(Llm::AnalyzePartialCloseout::AssessmentFailure)
      return CONFIGURATION_ERROR if error.is_a?(AgentHarness::ConfigurationError)
      return AUTHENTICATION_UNAVAILABLE if error.is_a?(AgentHarness::AuthenticationError)
      return TIMEOUT if error.is_a?(AgentHarness::TimeoutError)

      TRANSPORT_ERROR
    end

    def self.retryable?(error_or_category)
      category = error_or_category.is_a?(String) ? error_or_category : category_for(error_or_category)
      RETRYABLE_CATEGORIES.include?(category)
    end

    def self.operator_action?(category)
      OPERATOR_CATEGORIES.include?(category)
    end

    # The exact next step an operator or the recovery sweep has to take for a
    # failed category. Auth and configuration failures need a human; every
    # other category is retried automatically.
    def self.next_action_for(category)
      case category
      when AUTHENTICATION_UNAVAILABLE then "reconnect_runner_credential_then_retry"
      when CONFIGURATION_ERROR then "fix_runner_configuration_then_retry"
      when BUDGET_EXHAUSTED then "review_execution_budget_then_retry"
      when EXECUTION_PAUSED then "resume_execution_then_retry"
      else RECOVERY_ACTION
      end
    end
  end
end
