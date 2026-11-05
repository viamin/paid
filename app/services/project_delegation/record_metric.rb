# frozen_string_literal: true

module ProjectDelegation
  # @spec PROJECT-DELEGATION-007
  class RecordMetric
    def self.call(...) = new(...).call

    def initialize(project:, event_type:, intent_revision:, acceptance_revision:, evidence_revision:,
      cohort: "pilot", issue_key: nil, occurred_at: Time.current, reason_code: nil, metadata: {})
      @attributes = {
        project:, event_type:, cohort:, issue_key:, intent_revision:, acceptance_revision:,
        evidence_revision:, occurred_at:, reason_code:, metadata:
      }
    end

    def call
      ProjectDelegationMetric.create!(@attributes)
    end
  end
end
