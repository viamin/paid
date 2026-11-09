# frozen_string_literal: true

module ProjectDelegation
  # Production recorder for RDR-080 pilot lifecycle and stop evidence.
  # @spec PROJECT-DELEGATION-007
  class RecordPilotEvent
    STOP_EVENTS = {
      tenant: "tenant_breach",
      trust: "trust_breach",
      security: "security_breach",
      assessment_availability: "evidence_missing",
      evidence_revision: "evidence_missing",
      intent_revision: "decision_reversed",
      acceptance_revision: "decision_reversed"
    }.freeze

    class << self
      def issue_transition(issue)
        return unless issue.saved_change_to_paid_state?

        from, to = issue.saved_change_to_paid_state
        record_issue(issue, "issue_started") if to == "in_progress" && from != "in_progress"
        record_issue(issue, "issue_completed") if to == "completed" && from != "completed"
      end

      def human_decision(decision)
        issue = decision.feature_intent.issues.order(:id).first
        record(project: decision.feature_intent.project, issue:, event_type: "human_decision",
          event_key: "feature-intent-decision:#{decision.id}:resolved", occurred_at: decision.resolved_at,
          decision_started_at: decision.created_at, decision_resolved_at: decision.resolved_at)
      end

      def boundary_stop(authorization:, reasons:, boundary:)
        reasons.filter_map { |reason| STOP_EVENTS[reason.to_sym] }.uniq.each do |event_type|
          record(project: authorization.project, issue: authorization.issue, event_type:,
            event_key: "delegated-boundary:#{authorization.id}:#{boundary}:#{event_type}:#{authorization.updated_at.to_f}",
            material: event_type == "decision_reversed")
        end
      end

      private

      def record_issue(issue, event_type)
        record(project: issue.project, issue:, event_type:,
          event_key: "issue:#{issue.id}:#{event_type}:#{issue.updated_at.to_f}")
      end

      def record(project:, issue:, event_type:, event_key:, **attributes)
        return unless FeatureFlags.enabled?(:project_delegation, project:)

        posture = Posture.resolve_without_expansion(project)
        revisions = issue ? Automation::DelegatedActionAdmission.revision_tokens(issue:) : {}
        PilotMetrics.record(project:, issue:, event_type:, event_key:, posture:,
          policy_signature: posture.policy_signature, baseline: posture.conservative?, **revisions.symbolize_keys,
          **attributes)
      end
    end
  end
end
