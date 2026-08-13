# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkPrReadyActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      pr_review_phase: "draft")
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when PR is draft and mutation succeeds" do
      let(:pr_data) { double("pr_data", draft: true) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:mark_pull_request_ready)
          .and_return({ "id" => "PR_123", "isDraft" => false })
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "marks the PR as ready on GitHub" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:mark_pull_request_ready)
          .with(project.full_name, 42)
      end

      it "updates issue pr_review_phase to ready" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end

      it "adds the paid-ready label" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(project.full_name, 42, [ "paid-ready" ])
      end

      it "returns marked_ready: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:marked_ready]).to be true
      end
    end

    context "when PR is draft but mutation reports still draft" do
      let(:pr_data) { double("pr_data", draft: true) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:mark_pull_request_ready)
          .and_return({ "id" => "PR_123", "isDraft" => true })
      end

      it "returns marked_ready: false" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:marked_ready]).to be false
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("draft")
      end
    end

    context "when mutation response is missing isDraft key" do
      let(:pr_data) { double("pr_data", draft: true) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:mark_pull_request_ready)
          .and_return({ "id" => "PR_123" })
      end

      it "returns marked_ready: false" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:marked_ready]).to be false
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("draft")
      end
    end

    context "when label addition fails" do
      let(:pr_data) { double("pr_data", draft: true) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:mark_pull_request_ready)
          .and_return({ "id" => "PR_123", "isDraft" => false })
        allow(github_client).to receive(:add_labels_to_issue)
          .and_raise(GithubClient::Error, "Not found")
      end

      it "still returns marked_ready: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:marked_ready]).to be true
      end

      it "still updates the phase to ready" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when PR is already non-draft" do
      let(:pr_data) { double("pr_data", draft: false) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)
        allow(github_client).to receive(:mark_pull_request_ready)
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "skips the GitHub API call" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(github_client).not_to have_received(:mark_pull_request_ready)
      end

      it "updates issue phase to ready" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end
  end
end
