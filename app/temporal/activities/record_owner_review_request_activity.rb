# frozen_string_literal: true

module Activities
  # Stamps the PR HEAD sha a stale-owner-approval re-review request was
  # issued for, so the scanner does not re-request review from the owner on
  # every poll cycle for the same commit (#3656).
  class RecordOwnerReviewRequestActivity < BaseActivity
    activity_name "RecordOwnerReviewRequest"

    def execute(input)
      issue = Issue.find(input[:issue_id])
      head_sha = input[:head_sha]

      issue.update_columns(owner_review_requested_sha: head_sha)

      logger.info(
        message: "pr_review.owner_review_request_recorded",
        issue_id: issue.id,
        pr_number: issue.github_number,
        head_sha: head_sha
      )

      { issue_id: issue.id, owner_review_requested_sha: head_sha }
    end
  end
end
