# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkPrDraftActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      pr_review_phase: "ready",
      pr_followup_count: 2,
      draft_review_count: 1)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when the PR is ready and the mutation succeeds" do
      let(:pr_data) { double("pr_data", draft: false) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:convert_pull_request_to_draft)
          .and_return({ "id" => "PR_123", "isDraft" => true })
        allow(github_client).to receive(:remove_label_from_issue)
      end

      it "converts the PR to draft on GitHub" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:convert_pull_request_to_draft)
          .with(project.full_name, 42)
      end

      it "moves the issue back to the restarted phase and resets progress counters" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        issue.reload
        expect(issue.pr_review_phase).to eq("restarted")
        expect(issue.pr_followup_count).to eq(0)
        expect(issue.draft_review_count).to eq(0)
      end

      it "removes the paid-ready label" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:remove_label_from_issue)
          .with(project.full_name, 42, "paid-ready")
      end

      it "returns marked_draft: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:marked_draft]).to be true
      end
    end

    context "when the PR is already a draft" do
      let(:pr_data) { double("pr_data", draft: true) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:remove_label_from_issue)
      end

      it "does not call the GitHub draft mutation but still restarts the phase" do
        allow(github_client).to receive(:convert_pull_request_to_draft)

        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).not_to have_received(:convert_pull_request_to_draft)
        expect(issue.reload.pr_review_phase).to eq("restarted")
        expect(result[:marked_draft]).to be true
      end
    end

    context "when the mutation reports the PR is still not a draft" do
      let(:pr_data) { double("pr_data", draft: false) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:convert_pull_request_to_draft)
          .and_return({ "id" => "PR_123", "isDraft" => false })
      end

      it "returns marked_draft: false and does not change the phase" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:marked_draft]).to be false
        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when label removal fails" do
      let(:pr_data) { double("pr_data", draft: false) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:convert_pull_request_to_draft)
          .and_return({ "id" => "PR_123", "isDraft" => true })
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error, "Not found")
      end

      it "still demotes the PR (label removal is best-effort)" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:marked_draft]).to be true
        expect(issue.reload.pr_review_phase).to eq("restarted")
      end
    end
  end
end
