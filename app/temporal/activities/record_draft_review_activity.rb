# frozen_string_literal: true

module Activities
  # Records that a draft PR review round was triggered by incrementing
  # the draft_review_count. Uses the same idempotent pattern as
  # RecordPrFollowupActivity: the increment only applies when the
  # current count matches the expected value.
  class RecordDraftReviewActivity < BaseActivity
    activity_name "RecordDraftReview"

    def execute(input)
      issue = Issue.find_by(id: input[:issue_id])
      return { recorded: false } unless issue

      expected_count = input[:expected_draft_review_count]
      if expected_count
        issue.with_lock do
          issue.reload
          issue.increment!(:draft_review_count) if issue.draft_review_count == expected_count
        end
      else
        issue.increment!(:draft_review_count)
      end

      { recorded: true }
    end
  end
end
