# frozen_string_literal: true

module Activities
  # Resets an escalated PR back into an automation-managed phase after the
  # owner dismisses escalation by removing the paid-escalated label.
  class DismissEscalationActivity < BaseActivity
    activity_name "DismissEscalation"

    def execute(input)
      issue = Issue.find_by(id: input[:issue_id])
      return { dismissed: false } unless issue
      return { dismissed: false } unless issue.escalated_phase?

      issue.dismiss_escalation!(draft: input[:draft] == true)

      logger.info(
        message: "pr_review.escalation_dismissed",
        issue_id: issue.id,
        pr_number: issue.github_number,
        resumed_phase: issue.pr_review_phase
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
