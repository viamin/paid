# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DismissEscalationActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    context "when issue is in escalated phase" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "escalated",
          pr_followup_count: 2,
          review_goal_retry_count: 3,
          operational_failure_reset_at: 2.hours.ago,
          labels: [ "paid-generated", "paid-escalated", "paid-dismiss-escalation" ])
      end

      it "transitions pr_review_phase to ready" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end

      it "resets the review-goal retry breaker" do
        freeze_time do
          activity.execute(issue_id: issue.id)

          expect(issue.reload.review_goal_retry_reset_at).to be_within(1.second).of(Time.current)
        end
      end

      it "resets review_goal_retry_count to zero" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.review_goal_retry_count).to eq(0)
      end

      it "resets the operational failure breaker and follow-up counter" do
        freeze_time do
          activity.execute(issue_id: issue.id)

          issue.reload
          expect(issue.operational_failure_reset_at).to be_within(1.second).of(Time.current)
          expect(issue.pr_followup_count).to eq(0)
        end
      end

      it "cleans up stale escalation labels locally" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.labels).not_to include("paid-escalated", "paid-dismiss-escalation")
      end

      it "returns dismissed: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:dismissed]).to be true
        expect(result[:phase]).to eq("ready")
        expect(result[:current_followup_count]).to eq(0)
      end
    end

    context "when the escalated PR is still draft" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "escalated",
          draft_review_count: 4,
          pr_followup_count: 2,
          review_goal_retry_count: 3,
          labels: [ "paid-generated", "paid-escalated" ])
      end

      it "resets into restarted phase with fresh draft counters" do
        result = activity.execute(issue_id: issue.id, draft: true)

        issue.reload
        expect(result[:dismissed]).to be true
        expect(result[:phase]).to eq("restarted")
        expect(issue.pr_review_phase).to eq("restarted")
        expect(issue.draft_review_count).to eq(0)
        expect(issue.pr_followup_count).to eq(0)
      end
    end

    context "when issue is not in escalated phase" do
      let(:issue) do
        create(:issue, :pull_request, pr_review_phase: "ready")
      end

      it "returns dismissed: false" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:dismissed]).to be false
      end

      it "does not change the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when issue is missing" do
      it "returns dismissed: false" do
        result = activity.execute(issue_id: -1)

        expect(result[:dismissed]).to be false
      end
    end
  end
end
