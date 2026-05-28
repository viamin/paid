# frozen_string_literal: true

module AgentRunPatterns
  class RecordRemediationDecision
    DEDUPE_WINDOW = 24.hours

    def self.call(...)
      new(...).call
    end

    def initialize(account:, pattern:, diagnosis:)
      @account = account
      @pattern = pattern
      @diagnosis = diagnosis
    end

    def call
      RemediationDecision.transaction do
        existing = RemediationDecision
          .where(account: account, fingerprint: fingerprint)
          .where("created_at >= ?", DEDUPE_WINDOW.ago)
          .order(created_at: :desc)
          .lock
          .first

        if existing
          update_existing_decision(existing)
        else
          RemediationDecision.create!(decision_attributes)
        end
      end
    end

    private

    attr_reader :account, :diagnosis, :pattern

    def update_existing_decision(decision)
      decision.assign_attributes(
        decision_attributes.except(:status, :occurrence_count, :created_at)
      )
      decision.occurrence_count += 1
      decision.save!
      decision
    end

    def decision_attributes
      target = diagnosis.action_target.deep_stringify_keys

      {
        account: account,
        fingerprint: fingerprint,
        root_cause: diagnosis.root_cause,
        confidence: diagnosis.confidence,
        evidence_pointers: diagnosis.evidence_pointers,
        proposed_action: diagnosis.proposed_action,
        action_target_type: target["type"],
        action_target_id: target["id"],
        action_target_metadata: target.except("type", "id"),
        status: "proposed",
        revert_data: {},
        pre_remediation_failure_count: failure_count,
        post_remediation_failure_count: nil,
        outcome: nil,
        occurrence_count: 1
      }
    end

    def failure_count
      pattern.details[:streak_length] ||
        pattern.details[:failure_count] ||
        pattern.details[:occurrence_count] ||
        0
    end

    def fingerprint
      pattern.details[:fingerprint].to_s
    end
  end
end
