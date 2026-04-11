# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrphanBranchReaperJob do
  let(:project) { create(:project) }
  let(:github_client) { instance_double(GithubClient) }
  let(:job) { described_class.new }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:ref)
    allow(github_client).to receive(:pull_requests).and_return([])
    allow(github_client).to receive(:delete_ref)
  end

  def stub_branch_exists(branch_name)
    allow(github_client).to receive(:ref)
      .with(project.full_name, "heads/#{branch_name}")
      .and_return(instance_double(Sawyer::Resource))
  end

  def stub_branch_missing(branch_name)
    allow(github_client).to receive(:ref)
      .with(project.full_name, "heads/#{branch_name}")
      .and_raise(GithubClient::NotFoundError)
  end

  def stub_no_open_prs(branch_name)
    allow(github_client).to receive(:pull_requests)
      .with(project.full_name, state: "open", head: "#{project.owner}:#{branch_name}")
      .and_return([])
  end

  def stub_open_pr_exists(branch_name)
    allow(github_client).to receive(:pull_requests)
      .with(project.full_name, state: "open", head: "#{project.owner}:#{branch_name}")
      .and_return([ instance_double(Sawyer::Resource) ])
  end

  describe "#perform" do
    it "deletes a remote branch for a timed-out run with no PR" do
      create(:agent_run, :timeout,
        project: project,
        branch_name: "paid/262-feature-202f06",
        pull_request_url: nil,
        updated_at: 2.hours.ago)

      stub_branch_exists("paid/262-feature-202f06")
      stub_no_open_prs("paid/262-feature-202f06")
      allow(github_client).to receive(:delete_ref)

      job.perform

      expect(github_client).to have_received(:delete_ref)
        .with(project.full_name, "heads/paid/262-feature-202f06")
    end

    it "deletes a remote branch for a retried run with no PR" do
      create(:agent_run, :retried,
        project: project,
        branch_name: "paid/487-feature-d76f14",
        pull_request_url: nil,
        updated_at: 2.hours.ago)

      stub_branch_exists("paid/487-feature-d76f14")
      stub_no_open_prs("paid/487-feature-d76f14")
      allow(github_client).to receive(:delete_ref)

      job.perform

      expect(github_client).to have_received(:delete_ref)
        .with(project.full_name, "heads/paid/487-feature-d76f14")
    end

    it "deletes a remote branch for a failed run with no PR" do
      create(:agent_run, :failed,
        project: project,
        branch_name: "paid/100-feature-abc123",
        pull_request_url: nil,
        updated_at: 2.hours.ago)

      stub_branch_exists("paid/100-feature-abc123")
      stub_no_open_prs("paid/100-feature-abc123")
      allow(github_client).to receive(:delete_ref)

      job.perform

      expect(github_client).to have_received(:delete_ref)
        .with(project.full_name, "heads/paid/100-feature-abc123")
    end

    it "skips runs whose branch has an open PR" do
      create(:agent_run, :timeout,
        project: project,
        branch_name: "paid/262-feature-202f06",
        pull_request_url: nil,
        updated_at: 2.hours.ago)

      stub_branch_exists("paid/262-feature-202f06")
      stub_open_pr_exists("paid/262-feature-202f06")

      job.perform

      expect(github_client).not_to have_received(:delete_ref)
    end

    it "skips runs whose branch is already missing on the remote" do
      create(:agent_run, :retried,
        project: project,
        branch_name: "paid/488-feature-59e4fd",
        pull_request_url: nil,
        updated_at: 2.hours.ago)

      stub_branch_missing("paid/488-feature-59e4fd")

      job.perform

      expect(github_client).not_to have_received(:pull_requests)
    end

    it "skips completed runs" do
      create(:agent_run, :completed,
        project: project,
        branch_name: "paid/200-feature-fff000",
        updated_at: 2.hours.ago)

      job.perform

      expect(github_client).not_to have_received(:ref)
    end

    it "skips runs still within the grace period" do
      create(:agent_run, :timeout,
        project: project,
        branch_name: "paid/300-feature-aaa111",
        pull_request_url: nil,
        updated_at: 30.minutes.ago)

      job.perform

      expect(github_client).not_to have_received(:ref)
    end

    it "skips runs that have a pull_request_url" do
      create(:agent_run, :failed,
        project: project,
        branch_name: "paid/400-feature-bbb222",
        pull_request_url: "https://github.com/example/repo/pull/99",
        updated_at: 2.hours.ago)

      job.perform

      expect(github_client).not_to have_received(:ref)
    end

    it "handles GitHub API errors gracefully and continues" do
      create(:agent_run, :timeout, project: project,
        branch_name: "paid/500-error-branch", pull_request_url: nil, updated_at: 2.hours.ago)
      create(:agent_run, :failed, project: project,
        branch_name: "paid/501-good-branch", pull_request_url: nil, updated_at: 2.hours.ago)

      allow(github_client).to receive(:ref) do |_repo, ref|
        raise GithubClient::ApiError.new("Server error", status: 500) if ref.include?("500-error")
        instance_double(Sawyer::Resource)
      end
      stub_no_open_prs("paid/501-good-branch")
      allow(github_client).to receive(:delete_ref)

      job.perform

      expect(github_client).to have_received(:delete_ref)
        .with(project.full_name, "heads/paid/501-good-branch")
    end

    it "is idempotent when branches are already deleted" do
      create(:agent_run, :timeout,
        project: project,
        branch_name: "paid/600-already-gone",
        pull_request_url: nil,
        updated_at: 2.hours.ago)

      stub_branch_missing("paid/600-already-gone")

      2.times { job.perform }

      expect(github_client).not_to have_received(:delete_ref)
    end
  end
end
