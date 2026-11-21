# frozen_string_literal: true

module PartialCloseouts
  # Classifies a terminal acceptance-audit attempt so retry decisions never
  # guess from status alone: transient transport/infrastructure
  # unavailability is the only class the shared retry mechanism may re-run.
  # A completed audit — including one reporting unmet criteria or incomplete
  # input coverage — is a substantive assessment, never a retry candidate,
  # and changed evidence is a fresh logical audit through ordinary
  # admission, not a re-run of a stale attempt.
  # @spec PARTIAL-CLOSEOUT-056 PARTIAL-CLOSEOUT-058 AGENT-RETRY-016
  class AcceptanceAuditFailure
    MAX_DIAGNOSTIC_VALUE_LENGTH = 120
    MAX_DIAGNOSTIC_FIELDS = 10
    DIAGNOSTIC_KEYS = %w[category provider model request_id attempt_id at].freeze
    TRANSIENT_CATEGORIES = %w[transport_error timeout unsuccessful_response invalid_json invalid_assessment].freeze
    AUTHENTICATION_CATEGORIES = %w[authentication_unavailable].freeze
    TRANSIENT_MESSAGES = [
      "Partial closeout assessment transport failed.",
      "Partial closeout assessment timed out.",
      "partial closeout assessment failed: transport returned an unsuccessful response."
    ].freeze
    SUBSTANTIVE_STATUSES = %w[completed no_output].freeze
    SIGNATURE_STATUSES = %w[failed retried].freeze

    class << self
      def diagnostic_for(agent_run)
        diagnostic = agent_run.reconciliation.to_h.values_at("acceptance_audit_failure", "assessment_failure")
          .find { |value| value.is_a?(Hash) && value.present? }
        safe_diagnostic(diagnostic) if diagnostic
      end

      # @spec PARTIAL-CLOSEOUT-058
      def safe_diagnostic(diagnostic)
        source = diagnostic.stringify_keys
        result = source.slice(*DIAGNOSTIC_KEYS).compact.transform_values { |value| bounded_diagnostic_value(value) }
        result["category"] ||= "transport_error"
        fields = source["invalid_fields"].is_a?(Array) ? source["invalid_fields"] : []
        result["invalid_fields"] = fields.first(MAX_DIAGNOSTIC_FIELDS).filter_map do |field|
          next unless field.is_a?(Hash)

          field.stringify_keys.slice("path", "expected", "actual").compact
            .transform_values { |value| bounded_diagnostic_value(value) }
        end
        result
      end

      def classify(agent_run)
        return failure_signature(agent_run) if agent_run.status.in?(SIGNATURE_STATUSES)

        case agent_run.status
        when "timeout" then :transient_transport
        when "cancelled" then :cancelled
        when "auth_expired" then :authentication_or_configuration
        when "rate_limited" then :rate_limit_recovery_owned
        when "token_budget_exceeded" then :budget_exhausted
        when *SUBSTANTIVE_STATUSES then :substantive_assessment
        else :not_terminal
        end
      end

      def transient?(agent_run)
        classify(agent_run) == :transient_transport
      end

      private

      def bounded_diagnostic_value(value)
        return value.to_s.first(MAX_DIAGNOSTIC_VALUE_LENGTH) if value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Symbol)

        value.class.name.first(MAX_DIAGNOSTIC_VALUE_LENGTH)
      end

      # A "retried" run keeps the failure signature that justified its retry,
      # so the sweep can still distinguish a superseded transient attempt
      # from a deterministic one.
      def failure_signature(agent_run)
        category = agent_run.reconciliation.to_h.dig("acceptance_audit_failure", "category")
        return :transient_transport if category.in?(TRANSIENT_CATEGORIES)
        return :authentication_or_configuration if category.in?(AUTHENTICATION_CATEGORIES)
        return :transient_transport if transport_interruption?(agent_run)

        TRANSIENT_MESSAGES.any? { |message| agent_run.error_message.to_s.start_with?(message) } ? :transient_transport : :non_transient_failure
      end

      # Failure messages that name a transport-level interruption rather
      # than a permanent cause: the audit never obtained a usable answer. A
      # Temporal-level activity timeout never reaches the audit activity's
      # own rescue, so no typed category is recorded — the run is marked
      # failed with the runtime's timeout message instead — and an exhausted
      # runner pool never reached a runner (#5002 review).
      def transport_interruption?(agent_run)
        message = agent_run.error_message.to_s.downcase
        message.include?(AgentRun::ACTIVITY_TIMEOUT_MESSAGE.downcase) ||
          AgentRun::PROVIDER_UNAVAILABLE_KEYWORDS.any? { |keyword| message.include?(keyword.downcase) }
      end
    end
  end
end
