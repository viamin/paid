# frozen_string_literal: true

require "rails_helper"

RSpec.describe MainCi::MergeGate do
  let(:project) { create(:project, review_settings: { "main_ci_recovery" => {
    "enabled" => true, "required_workflows" => [ ".github/workflows/ci.yml" ], "executor_revision" => "e" * 40
  } }) }
  let(:client) { instance_double(GithubClient) }
  let(:head) { "b" * 40 }

  # @spec MAIN-CI-005 MAIN-CI-007
  it "fails closed before initialization and for ordinary PRs during an episode" do
    expect(described_class.allowed?(project: project, number: 42, head_sha: head, client: client)).to be(false)
    create(:agent_run, project: project)
    MainCiState.create!(project: project, account: project.account, status: "failing", episode_key: SecureRandom.uuid)
    expect(described_class.allowed?(project: project, number: 42, head_sha: head, client: client)).to be(false)
  end

  # @spec MAIN-CI-005
  it "admits only the recorded repair PR's exact head after full verification" do
    run = create(:agent_run, :completed, project: project, pull_request_number: 42, result_commit_sha: head)
    state = MainCiState.create!(project: project, account: project.account, status: "repair_queued",
      repair_run: run, episode_key: SecureRandom.uuid)
    run.update!(external_metadata: { "main_ci_episode" => state.episode_key })
    allow(client).to receive_messages(default_branch_head: { branch: "main", sha: "a" * 40 }, full_verification_runs: [ { id: 1, path: ".github/workflows/ci.yml",
      event: "pull_request", head_sha: head, status: "completed", conclusion: "success" } ])
    expect(described_class.allowed?(project: project, number: 42, head_sha: head, client: client)).to be(true)
    expect(described_class.allowed?(project: project, number: 42, head_sha: "c" * 40, client: client)).to be(false)
  end

  # @spec MAIN-CI-005
  it "enforces the stop at the provider merge boundary even without a local PR record" do
    adapter = Automation::Providers::Github::RepositoryProvider.new(project, client: client)
    expect(client).not_to receive(:merge_pull_request)
    expect do
      adapter.merge_pull_request(repo: project.full_name, number: 42, method: :squash, expected_head_sha: head)
    end.to raise_error(Automation::Providers::RepositoryProvider::ProviderError, /main CI recovery/)
  end

  # @spec MAIN-CI-005 MAIN-CI-006
  it "rechecks healthy main coverage and rejects an advanced tip at the final boundary" do
    MainCiState.create!(project: project, account: project.account, status: "healthy", verified_sha: head)
    result = { id: 1, path: ".github/workflows/ci.yml", event: "push", head_branch: "main",
      head_sha: head, status: "completed", conclusion: "success" }
    allow(client).to receive_messages(default_branch_head: { branch: "main", sha: head }, full_verification_runs: [ result ])
    expect(described_class.allowed?(project: project, number: 99, head_sha: head, client: client)).to be(true)
    allow(client).to receive(:full_verification_runs).and_return([ result.merge(conclusion: "failure") ])
    expect(described_class.allowed?(project: project, number: 99, head_sha: head, client: client)).to be(false)
    allow(client).to receive(:full_verification_runs).and_return([ result ])
    allow(client).to receive(:default_branch_head).and_return({ branch: "main", sha: head }, { branch: "main", sha: "c" * 40 })
    expect(described_class.allowed?(project: project, number: 99, head_sha: head, client: client)).to be(false)
  end
end
