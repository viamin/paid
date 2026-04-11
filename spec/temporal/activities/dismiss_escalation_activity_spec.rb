# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DismissEscalationActivity do
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when issue is in escalated phase" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "escalated",
          labels: [ "paid-generated", "paid-escalated", "paid-dismiss-escalation" ])
      end

      before do
        allow(github_client).to receive(:remove_label_from_issue)
      end

      it "transitions pr_review_phase to ready" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end

      it "removes the paid-dismiss-escalation label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:remove_label_from_issue)
          .with(issue.project.full_name, issue.github_number, "paid-dismiss-escalation")
      end

      it "removes the paid-escalated label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:remove_label_from_issue)
          .with(issue.project.full_name, issue.github_number, "paid-escalated")
      end

      it "returns dismissed: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:dismissed]).to be true
      end
    end

    context "when label removal fails" do
      let(:issue) do
        create(:issue, :pull_request, pr_review_phase: "escalated")
      end

      before do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error, "Not found")
      end

      it "still transitions the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end

      it "still returns dismissed: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:dismissed]).to be true
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
