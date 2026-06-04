# frozen_string_literal: true

module Activities
  # Converts a pull request back to a draft and moves the issue's
  # pr_review_phase to "restarted", removing the "paid-ready" phase label.
  #
  # Used when a Paid-generated PR was opened/marked ready but has not yet
  # received a code review: an unreviewed PR should not advertise itself as
  # ready for review/merge, so it is demoted to draft until the configured
  # reviewer has weighed in. Idempotent: skips the GitHub mutation when the
  # PR is already a draft, and only resets phase/counts when GitHub confirms
  # the PR is a draft.
  class MarkPrDraftActivity < BaseActivity
    activity_name "MarkPrDraft"

    PAID_READY_LABEL = "paid-ready"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      issue = Issue.find(input[:issue_id])

      client = project.client
      pr_data = client.pull_request(project.full_name, pr_number)

      if pr_data.draft
        logger.info(
          message: "pr_review.already_draft",
          project_id: project.id,
          pr_number: pr_number
        )
      else
        result = client.convert_pull_request_to_draft(project.full_name, pr_number)
        unless result["isDraft"] == true
          logger.warn(
            message: "pr_review.mark_draft_failed",
            project_id: project.id,
            pr_number: pr_number
          )
          return { marked_draft: false, pr_number: pr_number }
        end

        logger.info(
          message: "pr_review.marked_draft",
          project_id: project.id,
          pr_number: pr_number
        )
      end

      restart_phase!(issue)
      remove_phase_label(client, project, pr_number, PAID_READY_LABEL)

      { marked_draft: true, pr_number: pr_number }
    end

    private

    # Mirror the reset maybe_restart_draft applies so the scanner treats the
    # demoted PR like a fresh draft (clean review/followup counters) rather
    # than carrying stale ready-phase progress.
    def restart_phase!(issue)
      reset_at = Time.current
      issue.update!(
        pr_review_phase: "restarted",
        draft_review_count: 0,
        pr_followup_count: 0,
        review_goal_retry_count: 0,
        review_goal_retry_reset_at: reset_at,
        operational_failure_reset_at: reset_at,
        ci_retry_requested_at: nil
      )
    end
  end
end
