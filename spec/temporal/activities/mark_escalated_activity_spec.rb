# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkEscalatedActivity do
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when issue exists" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "updates pr_review_phase to escalated" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "adds the paid-escalated label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
      end

      it "returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end
    end

    context "when label addition fails" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
          .and_raise(GithubClient::Error, "Not found")
      end

      it "still updates the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "still returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end
    end

    context "when issue is missing" do
      it "returns updated: false" do
        result = activity.execute(issue_id: -1)

        expect(result[:updated]).to be false
      end
    end
  end
end
