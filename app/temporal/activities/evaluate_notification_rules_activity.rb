# frozen_string_literal: true

module Activities
  class EvaluateNotificationRulesActivity < BaseActivity
    activity_name "EvaluateNotificationRules"

    def execute(input)
      project = Project.find_by(id: input[:project_id])
      return { evaluated: false } unless project

      issue_scope = project.issues.where(id: Array(input[:issue_ids]))
      pr_scope = project.issues.where(id: Array(input[:pr_issue_ids]))

      Notifications::Rules::RepeatedNoChanges.call(scope: issue_scope)
      Notifications::Rules::StalledDraftPr.call(scope: pr_scope)
      Notifications::Rules::PrFollowupLimitReached.call(scope: pr_scope)
      Notifications::Rules::ScannerWedgedOnPendingReview.call(scope: Array(input[:pending_review_states]))

      { evaluated: true }
    end
  end
end
