# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MergePullRequestActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, merge_method: "squash", auto_merge_enabled: true) }
  let(:issue) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      pr_review_phase: "ready")
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when auto_merge is disabled" do
      before { project.update!(auto_merge_enabled: false) }

      it "returns skipped without calling GitHub" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result).to include(merged: false, skipped: true)
        expect(GithubClient).not_to have_received(:new)
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when PR is not yet merged" do
      let(:pr_data) { double("pr_data", merged_at: nil) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "merges the PR using project merge method" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:merge_pull_request)
          .with(project.full_name, 42, merge_method: "squash")
      end

      it "updates issue phase to merged" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("merged")
      end

      it "adds the paid-auto-merged label" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(project.full_name, 42, [ described_class::PAID_AUTO_MERGED_LABEL ])
      end

      it "returns merged: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be true
      end
    end

    context "when PR is already merged" do
      let(:pr_data) { double("pr_data", merged_at: Time.current) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "skips the merge call and label" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).not_to have_received(:merge_pull_request)
      end

      it "still updates issue phase to merged" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("merged")
      end

      # Intentional: already-merged PRs skip labeling because they may have
      # been merged manually by a human, not by this activity.
      it "does not add the paid-auto-merged label (may have been merged manually)" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).not_to have_received(:add_labels_to_issue)
      end
    end

    context "when labeling fails after merge" do
      let(:pr_data) { double("pr_data", merged_at: nil) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
        allow(github_client).to receive(:add_labels_to_issue)
          .and_raise(GithubClient::ApiError.new("Not found", status: 404))
      end

      it "does not raise and still returns merged: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be true
        expect(github_client).to have_received(:add_labels_to_issue)
      end
    end

    context "when merge fails with expected error (409 conflict)" do
      let(:pr_data) { double("pr_data", merged_at: nil) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
          .and_raise(GithubClient::ApiError.new("Merge conflict", status: 409))
      end

      it "returns merged: false" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be false
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end

      it "does not add the label" do
        allow(github_client).to receive(:add_labels_to_issue)

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).not_to have_received(:add_labels_to_issue)
      end
    end

    context "when merge fails with unexpected error (500)" do
      let(:pr_data) { double("pr_data", merged_at: nil) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
          .and_raise(GithubClient::ApiError.new("Server error", status: 500))
      end

      it "re-raises the error" do
        expect {
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)
        }.to raise_error(GithubClient::ApiError)
      end
    end

    context "with different merge methods" do
      let(:pr_data) { double("pr_data", merged_at: nil) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        project.update!(merge_method: "rebase")
        allow(github_client).to receive(:pull_request).and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "uses the project's configured merge method" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:merge_pull_request)
          .with(project.full_name, 42, merge_method: "rebase")
      end
    end
  end
end
