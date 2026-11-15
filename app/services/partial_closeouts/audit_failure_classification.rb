# frozen_string_literal: true

# frozen_string: true

module PartialCloseouts
  # Classifies a terminal acceptance-audit attempt for the shared retry
  # contract (docs/intent/agent-run-retry-contract/). Only transient
  # transport/infrastructure unavailability earns another automatic attempt:
  # a completed substantive assessment, invalid or stale input, an
  # authentication/configuration failure, cancellation, budget exhaustion,
  # and in-place rate-limit recovery each stop automatic attempts with their
  # own named reason so the supported operator action stays specific.
  # @spec PARTIAL-CLOSEOUT-056 AGENT-RETRY-014
  class AuditFailureClassification
    TYPED_CATEGORIES = {
      "transport_error" => :transient_infrastructure,
      "timeout" => :transient_infrastructure,
      "unsuccessful_response" => :transient_infrastructure,
      "invalid_json" => :invalid_input,
      "invalid_assessment" => :invalid_input,
      "authentication_unavailable" => :authentication_configuration
    }.freeze
    STATUS_CATEGORIES = {
      "completed" => :substantive_assessment,
      "cancelled" => :cancellation,
      "auth_expired" => :authentication_configuration,
      "token_budget_exceeded" => :budget_exhausted,
      "rate_limited" => :rate_limit_recovery,
      "timeout" => :transient_infrastructure,
      "retried" => :already_retried
    }.freeze
    TRANSIENT_MESSAGES = [
      "Partial closeout assessment transport failed.",
      "Partial closeout assessment timed out.",
      "partial closeout assessment failed: transport returned an unsuccessful response."
    ].freeze
    AUTHENTICATION_MESSAGE = "Partial closeout assessment could not authenticate"

    IN_FLIGHT_STATUSES = %w[queued pending running paused waiting_recovery].freeze

    def self.category(run)
      return :attempt_in_flight if run.status.in?(IN_FLIGHT_STATUSES)

      STATUS_CATEGORIES.fetch(run.status) { failed_category(run) }
    end

    def self.retryable?(run)
      category(run) == :transient_infrastructure
    end

    def self.failed_category(run)
      typed = run.reconciliation.to_h.dig("acceptance_audit_failure", "category")
      return TYPED_CATEGORIES.fetch(typed) if TYPED_CATEGORIES.key?(typed)
      return :authentication_configuration if authentication_message?(run)
      return :transient_infrastructure if transport_interruption?(run)

      :non_transient_failure
    end

    def self.authentication_message?(run)
      run.error_message.to_s.start_with?(AUTHENTICATION_MESSAGE)
    end

    # Failure signatures that name a transport-level interruption rather than
    # a permanent cause: the audit never obtained a usable answer. Covers a
    # Temporal activity timeout that ends the audit before its own rescue can
    # record a typed category, and an exhausted runner pool that never
    # reached a runner (#5002 review).
    def self.transport_interruption?(run)
      message = run.error_message.to_s
      return true if TRANSIENT_MESSAGES.any? { |prefix| message.start_with?(prefix) }

      normalized = message.downcase
      normalized.include?(AgentRun::ACTIVITY_TIMEOUT_MESSAGE.downcase) ||
        AgentRun::PROVIDER_UNAVAILABLE_KEYWORDS.any? { |keyword| normalized.include?(keyword.downcase) }
    end
  end
end
