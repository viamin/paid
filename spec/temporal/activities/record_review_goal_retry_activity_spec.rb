# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordReviewGoalRetryActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    it "increments the review_goal_retry_count on the issue" do
      issue = create(:issue, project: project, review_goal_retry_count: 0)

      result = activity.execute(issue_id: issue.id)

      expect(issue.reload.review_goal_retry_count).to eq(1)
      expect(result[:review_goal_retry_count]).to eq(1)
    end

    it "increments from an existing count" do
      issue = create(:issue, project: project, review_goal_retry_count: 2)

      activity.execute(issue_id: issue.id)

      expect(issue.reload.review_goal_retry_count).to eq(3)
    end
  end
end
