# frozen_string_literal: true

module ProjectDelegation
  # Groups related material product questions and presents them for human
  # settlement. Once settled, binds answers to immutable design and acceptance
  # revisions. Prevents re-asking settled questions downstream unless new
  # evidence conflicts, invalidates, or materially expands the revision.
  #
  # @spec PROJECT-DELEGATION-002
  module IntentCheckpoint
    # Represents a material question grouping with recommendation,
    # alternatives, consequences, affected scope, and evidence
    class Plan
      attr_reader :issue, :questions, :recommendation, :alternatives,
                  :consequences, :affected_scope, :evidence

      def initialize(issue:, questions: [], recommendation: nil,
                     alternatives: [], consequences: [],
                     affected_scope: [], evidence: {})
        @issue = issue
        @questions = questions
        @recommendation = recommendation
        @alternatives = alternatives
        @consequences = consequences
        @affected_scope = affected_scope
        @evidence = evidence
      end

      def self.for_issue(issue)
        # Placeholder: gather related product questions for the issue
        # This would analyze the issue title/body, acceptance criteria,
        # feature intent, and assess which questions need settlement
        new(
          issue: issue,
          questions: [],
          recommendation: nil,
          alternatives: [],
          consequences: [],
          affected_scope: [],
          evidence: {}
        )
      end

      def to_h
        {
          issue_id: issue.id,
          questions: questions,
          recommendation: recommendation,
          alternatives: alternatives,
          consequences: consequences,
          affected_scope: affected_scope,
          evidence: evidence
        }
      end
    end

    # Records settled answers bound to immutable design/acceptance revision
    class SettledAnswers
      attr_reader :plan, :answers, :settled_by, :settled_at,
                  :design_revision, :acceptance_revision

      def initialize(plan:, answers: {}, settled_by:, design_revision: nil,
                     acceptance_revision: nil)
        @plan = plan
        @answers = answers
        @settled_by = settled_by
        @settled_at = Time.current
        @design_revision = design_revision
        @acceptance_revision = acceptance_revision
      end

      def record_audit_event
        ProjectDelegationAuditEvent.record(
          project: plan.issue.project,
          account: plan.issue.project.account,
          event_type: ProjectDelegationAuditEvent::CHECKPOINT_SETTLED,
          actor: settled_by,
          event_data: {
            issue_id: plan.issue.id,
            questions: plan.questions,
            answers: answers
          },
          evidence_snapshot: {
            design_revision: design_revision,
            acceptance_revision: acceptance_revision
          }
        )
      end
    end
  end
end
