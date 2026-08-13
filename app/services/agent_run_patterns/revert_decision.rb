# frozen_string_literal: true

module AgentRunPatterns
  class RevertDecision
    def self.call(...)
      new(...).call
    end

    def initialize(decision:, actor: nil)
      @decision = decision
      @actor = actor
    end

    def call
      return decision unless decision.revertable?

      RemediationDecision.transaction do
        decision.lock!
        decision.reload
        return decision unless decision.revertable?

        case revert_data.fetch("handler")
        when "mark_runner_unavailable"
          revert_mark_runner_unavailable!
        when "clear_runner_field"
          revert_clear_runner_field!
        when "disable_runner_fallback"
          revert_disable_runner_fallback!
        when "file_issue"
          revert_file_issue!
        when "notify"
          nil
        end

        decision.update!(status: "reverted")
        record_audit_event
      end

      decision
    end

    private

    attr_reader :actor, :decision

    def revert_data
      decision.revert_data.to_h
    end

    def revert_mark_runner_unavailable!
      runner = Runner.find(revert_data.fetch("runner_id"))
      state = runner.user.runner_states.find_or_create_by!(runner_name: revert_data.fetch("runner_state_name")) do |record|
        record.failure_count = 0
        record.circuit_state = "closed"
      end
      previous_reset_at = revert_data["previous_rate_limited_until"]

      if previous_reset_at.present?
        state.update!(rate_limited_until: Time.zone.parse(previous_reset_at))
      else
        state.clear_rate_limit!
      end
    end

    def revert_clear_runner_field!
      runner = Runner.find(revert_data.fetch("runner_id"))
      runner.update!(revert_data.fetch("field_name") => revert_data["previous_value"])
    end

    def revert_disable_runner_fallback!
      runner = Runner.find(revert_data.fetch("runner_id"))
      runner.update!(enabled_for_fallback: revert_data.fetch("previous_enabled_for_fallback"))
    end

    def revert_file_issue!
      incident = ExceptionIncident.find_by(id: revert_data["incident_id"])
      return unless incident

      incident.update!(status: "resolved", resolved_at: Time.current)
    end

    def record_audit_event
      subject = Runner.find_by(id: revert_data["runner_id"]) || decision.account

      Audit::RecordEvent.call(
        account: decision.account,
        action: "self_heal.remediation_reverted",
        actor: actor,
        subject: subject,
        metadata: {
          remediation_action: decision.proposed_action,
          remediation_decision_id: decision.id,
          target_label: decision.action_target_label,
          details: [
            "Reverted remediation decision ##{decision.id}",
            "Fingerprint: #{decision.fingerprint}"
          ]
        }
      )
    end
  end
end
