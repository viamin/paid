# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordDraftReviewActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    context "when issue is missing" do
      it "returns recorded: false" do
        result = activity.execute(issue_id: -1)

        expect(result[:recorded]).to be false
      end
    end

    context "when recording a draft review" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft",
          draft_review_count: 0)
      end

      it "increments draft_review_count" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.draft_review_count).to eq(1)
      end

      it "returns recorded: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:recorded]).to be true
      end
    end

    context "with expected_draft_review_count for idempotency" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft",
          draft_review_count: 2)
      end

      it "increments when expected count matches current" do
        activity.execute(issue_id: issue.id, expected_draft_review_count: 2)

        expect(issue.reload.draft_review_count).to eq(3)
      end

      it "does not increment when expected count does not match (retry scenario)" do
        activity.execute(issue_id: issue.id, expected_draft_review_count: 1)

        expect(issue.reload.draft_review_count).to eq(2)
      end

      it "is idempotent on double execution with same expected count" do
        activity.execute(issue_id: issue.id, expected_draft_review_count: 2)
        activity.execute(issue_id: issue.id, expected_draft_review_count: 2)

        expect(issue.reload.draft_review_count).to eq(3)
      end
    end
  end
end
