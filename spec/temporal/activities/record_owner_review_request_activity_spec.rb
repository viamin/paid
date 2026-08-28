# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordOwnerReviewRequestActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, :pull_request, project: project, github_number: 42)
  end

  # @spec AUTO-MERGE-007
  describe "#execute" do
    it "stamps owner_review_requested_sha on the issue" do
      activity.execute(issue_id: issue.id, head_sha: "abc123")

      expect(issue.reload.owner_review_requested_sha).to eq("abc123")
    end

    it "overwrites a previously stamped sha" do
      issue.update!(owner_review_requested_sha: "old-sha")

      activity.execute(issue_id: issue.id, head_sha: "new-sha")

      expect(issue.reload.owner_review_requested_sha).to eq("new-sha")
    end

    it "returns the issue_id and stamped sha" do
      result = activity.execute(issue_id: issue.id, head_sha: "abc123")

      expect(result).to eq(issue_id: issue.id, owner_review_requested_sha: "abc123")
    end

    it "logs the stamp with the standard pr_review logging component" do
      allow(Rails.logger).to receive(:info)

      activity.execute(issue_id: issue.id, head_sha: "abc123")

      expect(Rails.logger).to have_received(:info).with(
        message: "pr_review.owner_review_request_recorded",
        issue_id: issue.id,
        pr_number: 42,
        head_sha: "abc123"
      )
    end
  end
end
