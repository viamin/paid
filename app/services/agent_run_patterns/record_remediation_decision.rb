# frozen_string_literal: true

module AgentRunPatterns
  # @spec RUN-OBSTACLE-001
  # @spec RUN-OBSTACLE-003
  class RecordRemediationDecision
    DEDUPE_WINDOW = 24.hours
    DEDUPE_PROTECTED_FIELDS = %i[
      status
      occurrence_count
      diagnosis_attempted_on
      diagnosis_attempt_count_on_day
      last_diagnosis_attempt_at
      created_at
      revert_data
      outcome
      post_remediation_failure_count
      pre_remediation_exposure_count
      post_remediation_exposure_count
      dismissal_reason
      dismissed_at
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(account:, pattern:, diagnosis:)
      @account = account
      @pattern = pattern
      @diagnosis = diagnosis
    end

    def call
      recorded_at = Time.current

      RemediationDecision.transaction do
        existing = RemediationDecision
          .where(dedupe_scope)
          .where(status: %w[proposed dismissed])
          .where("created_at >= ?", DEDUPE_WINDOW.ago)
          .order(created_at: :desc)
          .lock
          .first

        if existing
          update_existing_decision(existing, recorded_at)
        else
          RemediationDecision.create!(decision_attributes(recorded_at))
        end
      end
    end

    private

    attr_reader :account, :diagnosis, :pattern

    def update_existing_decision(decision, recorded_at)
      decision.assign_attributes(
        decision_attributes(recorded_at).except(*DEDUPE_PROTECTED_FIELDS)
      )
      decision.occurrence_count += 1
      record_attempt!(decision, recorded_at)
      decision.save!
      decision
    end

    def decision_attributes(recorded_at)
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
        obstacle_kind: diagnosis.obstacle_kind,
        proposal_context: proposal_context,
        revert_data: {},
        pre_remediation_failure_count: failure_count,
        pre_remediation_exposure_count: exposure_count,
        post_remediation_failure_count: nil,
        outcome: nil,
        occurrence_count: 1,
        diagnosis_attempted_on: recorded_at.to_date,
        diagnosis_attempt_count_on_day: 1,
        last_diagnosis_attempt_at: recorded_at
      }
    end

    def record_attempt!(decision, recorded_at)
      if decision.diagnosis_attempted_on == recorded_at.to_date
        decision.diagnosis_attempt_count_on_day += 1
      else
        decision.diagnosis_attempted_on = recorded_at.to_date
        decision.diagnosis_attempt_count_on_day = 1
      end

      decision.last_diagnosis_attempt_at = recorded_at
    end

    def dedupe_scope
      target = diagnosis.action_target.deep_stringify_keys

      {
        account: account,
        fingerprint: fingerprint,
        action_target_type: target["type"],
        action_target_id: target["id"],
        action_target_metadata: target.except("type", "id")
      }
    end

    def failure_count
      pattern.details[:streak_length] ||
        pattern.details[:failure_count] ||
        pattern.details[:occurrence_count] ||
        0
    end

    def exposure_count
      pattern.details[:total_runs] ||
        pattern.details[:total_count] ||
        pattern.details.dig(:evidence_bundle, :aggregate_stats, :run_count) ||
        0
    end

    def proposal_context
      {
        "goal" => pattern.goal,
        "pattern_type" => pattern.type.to_s,
        "window_hours" => AgentRunPatterns::Detect::DEFAULT_WINDOW_HOURS,
        "affected_scope" => affected_scope,
        "evidence_bundle" => pattern.details[:evidence_bundle],
        "validation_plan" => diagnosis.validation_plan,
        "uncertainty" => diagnosis.uncertainty
      }
    end

    def affected_scope
      evidence = pattern.details[:evidence_bundle].to_h
      evidence.fetch(:aggregate_stats, evidence.fetch("aggregate_stats", {}))
    end

    def fingerprint
      pattern.details[:fingerprint].to_s
    end
  end
end
