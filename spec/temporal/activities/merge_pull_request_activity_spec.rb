# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MergePullRequestActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, merge_method: "squash") }
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
    context "when PR is not yet merged" do
      let(:pr_data) { double("pr_data", merged_at: nil) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
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
      end

      it "skips the merge call" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).not_to have_received(:merge_pull_request)
      end

      it "still updates issue phase to merged" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("merged")
      end
    end

    context "with different merge methods" do
      let(:pr_data) { double("pr_data", merged_at: nil) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        project.update!(merge_method: "rebase")
        allow(github_client).to receive(:pull_request).and_return(pr_data)
        allow(github_client).to receive(:merge_pull_request)
      end

      it "uses the project's configured merge method" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:merge_pull_request)
          .with(project.full_name, 42, merge_method: "rebase")
      end
    end
  end
end
