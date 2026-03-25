# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkEscalatedActivity do
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:add_comment)
  end

  describe "#execute" do
    context "when issue exists" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft",
          draft_review_count: 3)
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

      it "posts an escalation comment" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(issue.project.full_name, issue.github_number, a_string_including("Escalation Note"))
      end

      it "includes the default reason when no reason is provided" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("automated draft review limit"))
      end

      it "includes questions in the escalation comment" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("**Questions:**"))
      end

      it "uses a custom reason when provided" do
        activity.execute(issue_id: issue.id, reason: "Draft review limit reached")

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("Draft review limit reached"))
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

    context "when comment posting fails" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
        allow(github_client).to receive(:add_comment)
          .and_raise(GithubClient::Error, "API error")
      end

      it "still updates the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "still adds the label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
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
