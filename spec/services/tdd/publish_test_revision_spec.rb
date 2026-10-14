# frozen_string_literal: true

require "rails_helper"

# @spec TDD-PR-007 UPSTREAM-GATE-006
RSpec.describe Tdd::PublishTestRevision do
  let(:project) { create(:project, owner: "acme", repo: "alpha") }
  let(:github_client) { instance_double(GithubClient) }
  let(:agent_run) do
    create(:agent_run, :existing_pr, project: project, tdd_phase: "test_writing",
      result_commit_sha: "abc123def456789012345678901234567890abcd")
  end
  let!(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42,
      labels: [ "paid-test-changes-requested" ], tdd_review_state: "changes_requested")
  end

  before do
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive(:add_labels_to_issue)
    allow(github_client).to receive(:remove_label_from_issue)
  end

  it "returns a revised test commit to review and removes the preceding rejection" do
    allow(github_client).to receive(:remove_label_from_issue)
      .with(project.full_name, 42, "paid-tests-approved")
      .and_raise(GithubClient::NotFoundError, "Label does not exist")

    result = described_class.call(agent_run: agent_run)

    expect(result).to be_success
    expect(github_client).to have_received(:add_labels_to_issue)
      .with(project.full_name, 42, [ "paid-tests-ready-for-review" ])
    expect(github_client).to have_received(:remove_label_from_issue)
      .with(project.full_name, 42, "paid-test-changes-requested")
    expect(github_client).not_to have_received(:remove_label_from_issue)
      .with(project.full_name, 42, "paid-tests-approved")
    expect(pull_request.reload.labels).to contain_exactly("paid-tests-ready-for-review")
  end

  it "does not remove verdict labels when the pull request has no verdict" do
    pull_request.update!(labels: [])

    result = described_class.call(agent_run: agent_run)

    expect(result).to be_success
    expect(github_client).not_to have_received(:remove_label_from_issue)
    expect(pull_request.reload.labels).to contain_exactly("paid-tests-ready-for-review")
  end

  it "does not claim a new local revision when label synchronization partially fails" do
    allow(github_client).to receive(:remove_label_from_issue)
      .with(project.full_name, 42, "paid-tests-approved")
    allow(github_client).to receive(:remove_label_from_issue)
      .with(project.full_name, 42, "paid-test-changes-requested")
      .and_raise(GithubClient::ApiError.new("503 unavailable"))

    result = described_class.call(agent_run: agent_run)

    expect(result).not_to be_success
    expect(result.error).to eq(:label_sync_failed)
    expect(pull_request.reload.labels).to contain_exactly("paid-test-changes-requested")
  end

  it "does not reset the verdict without a published commit" do
    agent_run.update!(result_commit_sha: nil)

    result = described_class.call(agent_run: agent_run)

    expect(result).not_to be_success
    expect(result.error).to eq(:no_published_commit)
    expect(github_client).not_to have_received(:add_labels_to_issue)
    expect(pull_request.reload.labels).to contain_exactly("paid-test-changes-requested")
  end

  it "resets the local control gate for a revised test commit" do
    project.update!(label_integration_mode: "ignored")

    result = described_class.call(agent_run: agent_run)

    expect(result).to be_success
    expect(pull_request.reload.tdd_review_state).to eq("ready_for_review")
    expect(github_client).not_to have_received(:add_labels_to_issue)
  end

  it "does not write test-review labels to an upstream pull request" do
    project.update!(pr_target: "upstream", upstream_full_name: "upstream/alpha")

    result = described_class.call(agent_run: agent_run)

    expect(result).not_to be_success
    expect(result.error).to eq(:upstream_labeling_disabled)
    expect(github_client).not_to have_received(:add_labels_to_issue)
    expect(github_client).not_to have_received(:remove_label_from_issue)
    expect(pull_request.reload.labels).to contain_exactly("paid-test-changes-requested")
  end

  it "resets the local control gate for an upstream pull request" do
    project.update!(
      label_integration_mode: "ignored",
      pr_target: "upstream",
      upstream_full_name: "upstream/alpha"
    )

    result = described_class.call(agent_run: agent_run)

    expect(result).to be_success
    expect(pull_request.reload.tdd_review_state).to eq("ready_for_review")
    expect(github_client).not_to have_received(:add_labels_to_issue)
  end
end
