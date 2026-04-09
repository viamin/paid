# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrphanBranchReaperJob do
  describe "#perform" do
    let(:project) { create(:project, owner: "viamin", repo: "paid") }
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:new).and_return(github_client)
    end

    def create_orphan_run(status:, branch_name: "paid/123-feature-abc123", updated_at: 2.hours.ago, **attrs)
      create(:agent_run,
        status: status,
        project: project,
        branch_name: branch_name,
        pull_request_url: nil,
        pull_request_number: nil,
        updated_at: updated_at,
        **attrs)
    end

    context "when branch exists on remote with no open PR" do
      before do
        allow(github_client).to receive(:ref)
        allow(github_client).to receive(:pull_requests).and_return([])
        allow(github_client).to receive(:delete_ref)
      end

      it "deletes the branch for a timed-out run" do
        create_orphan_run(status: "timeout")

        described_class.perform_now

        expect(github_client).to have_received(:delete_ref)
          .with("viamin/paid", "heads/paid/123-feature-abc123")
      end

      it "deletes the branch for a retried run" do
        create_orphan_run(status: "retried")

        described_class.perform_now

        expect(github_client).to have_received(:delete_ref)
          .with("viamin/paid", "heads/paid/123-feature-abc123")
      end

      it "deletes the branch for a failed run" do
        create_orphan_run(status: "failed")

        described_class.perform_now

        expect(github_client).to have_received(:delete_ref)
          .with("viamin/paid", "heads/paid/123-feature-abc123")
      end
    end

    context "when branch is already gone from remote" do
      before do
        allow(github_client).to receive(:ref)
          .and_raise(GithubClient::NotFoundError.new)
        allow(github_client).to receive(:delete_ref)
      end

      it "does not attempt deletion" do
        create_orphan_run(status: "timeout")

        described_class.perform_now

        expect(github_client).not_to have_received(:delete_ref)
      end
    end

    context "when branch has an open PR" do
      before do
        allow(github_client).to receive(:ref)
        allow(github_client).to receive(:pull_requests)
          .and_return([ instance_double(Sawyer::Resource) ])
        allow(github_client).to receive(:delete_ref)
      end

      it "skips deletion" do
        create_orphan_run(status: "timeout")

        described_class.perform_now

        expect(github_client).to have_received(:pull_requests)
          .with("viamin/paid", state: "open", head: "viamin:paid/123-feature-abc123")
        expect(github_client).not_to have_received(:delete_ref)
      end
    end

    context "when AgentRun status is completed" do
      before do
        allow(github_client).to receive(:ref)
      end

      it "is not selected as a candidate" do
        create(:agent_run, :completed,
          project: project,
          branch_name: "paid/456-other-branch",
          updated_at: 2.hours.ago)

        described_class.perform_now

        expect(github_client).not_to have_received(:ref)
      end
    end

    context "when AgentRun is within the grace period" do
      before do
        allow(github_client).to receive(:ref)
        allow(github_client).to receive(:pull_requests).and_return([])
        allow(github_client).to receive(:delete_ref)
      end

      it "is excluded from candidates" do
        create_orphan_run(status: "timeout", updated_at: 30.minutes.ago)

        described_class.perform_now

        expect(github_client).not_to have_received(:ref)
      end
    end

    context "when a GitHub API error occurs" do
      before do
        allow(github_client).to receive(:ref)
        allow(github_client).to receive(:pull_requests).and_return([])
        allow(github_client).to receive(:delete_ref)
          .and_raise(GithubClient::ApiError.new("Server Error", status: 500))
      end

      it "logs the error and continues" do
        create_orphan_run(status: "failed")

        expect { described_class.perform_now }.not_to raise_error
      end
    end

    context "with multiple candidate runs" do
      before do
        allow(github_client).to receive(:ref)
        allow(github_client).to receive(:pull_requests).and_return([])
        allow(github_client).to receive(:delete_ref)
      end

      it "processes each independently" do
        create_orphan_run(status: "timeout", branch_name: "paid/1-branch-a")
        create_orphan_run(status: "retried", branch_name: "paid/2-branch-b")
        create_orphan_run(status: "failed", branch_name: "paid/3-branch-c")

        described_class.perform_now

        expect(github_client).to have_received(:delete_ref).exactly(3).times
      end
    end

    context "when AgentRun already has a pull_request_url" do
      before do
        allow(github_client).to receive(:ref)
      end

      it "is not selected as a candidate" do
        create(:agent_run, :completed,
          project: project,
          branch_name: "paid/789-feature",
          pull_request_url: "https://github.com/viamin/paid/pull/42",
          pull_request_number: 42,
          updated_at: 2.hours.ago)

        described_class.perform_now

        expect(github_client).not_to have_received(:ref)
      end
    end

    context "when AgentRun has no branch_name" do
      before do
        allow(github_client).to receive(:ref)
      end

      it "is not selected as a candidate" do
        create_orphan_run(status: "failed", branch_name: nil)

        described_class.perform_now

        expect(github_client).not_to have_received(:ref)
      end
    end
  end
end
