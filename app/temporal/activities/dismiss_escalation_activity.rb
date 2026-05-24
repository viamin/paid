# frozen_string_literal: true

module Activities
  # Returns an escalated PR back into an automation-managed phase after the
  # owner dismisses escalation by removing the paid-escalated label. This
  # preserves the existing failure streak; only real progress clears stuck
  # state.
  class DismissEscalationActivity < BaseActivity
    activity_name "DismissEscalation"

    def execute(input)
      issue = Issue.find_by(id: input[:issue_id])
      return { dismissed: false } unless issue
      unless issue.escalated_phase?
        OrchestrationDecision.record(
          project: issue.project,
          issue: issue,
          decision_point: "dismiss_escalation",
          action: "resume",
          status: "noop",
          signals: {
            trigger: "dismiss_escalation",
            draft: input[:draft] == true,
            phase_before: issue.pr_review_phase
          },
          result: {
            dismissed: false,
            phase: issue.pr_review_phase
          }
        )
        return { dismissed: false }
      end

      issue.dismiss_escalation!(draft: input[:draft] == true)

      logger.info(
        message: "pr_review.escalation_dismissed",
        issue_id: issue.id,
        pr_number: issue.github_number,
        resumed_phase: issue.pr_review_phase
      )

      OrchestrationDecision.record(
        project: issue.project,
        issue: issue,
        decision_point: "dismiss_escalation",
        action: "resume",
        status: "applied",
        signals: {
          trigger: "dismiss_escalation",
          draft: input[:draft] == true,
          phase_before: "escalated"
        },
        result: {
          dismissed: true,
          phase: issue.pr_review_phase,
          review_goal_retry_count: issue.review_goal_retry_count,
          pr_followup_count: issue.pr_followup_count
        }
      )

      {
        dismissed: true,
        issue_id: issue.id,
        pr_number: issue.github_number,
        phase: issue.pr_review_phase,
        current_draft_review_count: issue.draft_review_count,
        current_followup_count: issue.pr_followup_count
      }
    end
  end
end
