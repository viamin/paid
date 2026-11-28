# frozen_string_literal: true

require "rails_helper"

RSpec.describe MainCi::Reconcile do
  let(:sha) { "a" * 40 }
  let(:path) { ".github/workflows/ci.yml" }
  let(:project) { create(:project, review_settings: { "main_ci_recovery" => {
    "enabled" => true, "required_workflows" => [ path ], "executor_revision" => "e" * 40
  } }) }
  let(:client) { instance_double(GithubClient) }
  let(:run) { { id: 101, path: path, event: "push", head_branch: "main", head_sha: sha,
                status: "completed", conclusion: "failure", html_url: "https://github.com/o/r/actions/runs/101" } }

  before do
    allow(client).to receive(:default_branch_head).with(project.full_name).and_return({ branch: "main", sha: sha })
    allow(client).to receive(:full_verification_runs).and_return([ run ])
    allow(client).to receive_messages(check_runs_for_ref: [], check_run_log: "")
    allow(MainCi::Dispatch).to receive(:call)
  end

  def reconcile = described_class.call(project: project, client: client)

  # @spec MAIN-CI-002 MAIN-CI-006
  it "retains one episode across duplicate failures and clears only complete current main success" do
    reconcile
    state = MainCiState.find_by!(project: project)
    episode = state.episode_key
    expect(state).to be_blocked
    expect(state.evidence.fetch("failed_runs").first.fetch("id")).to eq(101)
    reconcile
    expect(state.reload.episode_key).to eq(episode)
    allow(client).to receive(:full_verification_runs).and_return([])
    reconcile
    expect(state.reload).to be_blocked
    allow(client).to receive(:full_verification_runs).and_return([ run.merge(conclusion: "success") ])
    reconcile
    expect(state.reload).not_to be_blocked
    expect(state.verified_sha).to eq(sha)
  end

  # @spec MAIN-CI-006
  it "rejects a snapshot when main advances during reconciliation" do
    allow(client).to receive(:default_branch_head).and_return({ branch: "main", sha: sha }, { branch: "main", sha: "b" * 40 })
    reconcile
    expect(MainCiState.find_by(project: project)).to be_nil
  end

  # @spec MAIN-CI-002 MAIN-CI-006
  it "never trusts green pull-request or skipped workflow coverage" do
    [ run.merge(event: "pull_request", conclusion: "success"), run.merge(conclusion: "skipped") ].each do |result|
      allow(client).to receive(:full_verification_runs).and_return([ result ])
      reconcile
      expect(MainCiState.find_by!(project: project)).to be_blocked
    end
  end

  # @spec MAIN-CI-007
  it "does no provider work when disabled" do
    project.update!(review_settings: {})
    expect(client).not_to receive(:default_branch_head)
    reconcile
    expect(MainCiState.find_by(project: project)).to be_nil
  end

  # @spec MAIN-CI-002 MAIN-CI-003 MAIN-CI-004 MAIN-CI-005 MAIN-CI-006
  it "rehearses failure, deduplicated repair, narrow PR admission and full-main recovery" do
    stub_const("ENV", ENV.to_h.merge("PAID_EXECUTOR_REVISION" => "e" * 40))
    allow(MainCi::Dispatch).to receive(:call).and_call_original
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])
    started = Time.current
    state = reconcile
    repair = state.repair_run
    expect(state.dispatched_at - started).to be < 60
    reconcile
    expect(state.reload.repair_run_id).to eq(repair.id)
    repair.update!(status: "completed", pull_request_number: 42, result_commit_sha: "c" * 40)
    allow(client).to receive(:full_verification_runs).with(project.full_name, sha: "c" * 40, branch: "main", event: "pull_request")
      .and_return([ run.merge(head_sha: "c" * 40, event: "pull_request", conclusion: "success") ])
    expect(MainCi::MergeGate.allowed?(project: project, number: 42, head_sha: "c" * 40, client: client)).to be(true)
    allow(client).to receive(:default_branch_head).and_return({ branch: "main", sha: "d" * 40 })
    allow(client).to receive(:full_verification_runs).with(project.full_name, sha: "d" * 40, branch: "main", event: "push")
      .and_return([ run.merge(head_sha: "d" * 40, conclusion: "success") ])
    2.times { reconcile } # Duplicate or late failure events still read current main.
    expect(state.reload).not_to be_blocked
    expect(state.verified_sha).to eq("d" * 40)
    expect(state.evidence["failure_history"]).to be_present
  end

  # @spec MAIN-CI-001 MAIN-CI-006
  it "retains a failure across intervening merges without reviving failures behind a repaired baseline" do
    allow(client).to receive(:full_verification_runs).with(project.full_name, sha: sha, branch: "main", event: "push").and_return([])
    allow(client).to receive(:full_verification_runs).with(project.full_name, branch: "main")
      .and_return([ run.merge(head_sha: "b" * 40) ])
    current_head = { branch: "main", sha: sha }
    allow(client).to receive_messages(compare: Struct.new(:status).new("ahead"), default_branch_head: current_head)
    state = reconcile
    expect(state.failed_sha).to eq("b" * 40)
    allow(client).to receive(:full_verification_runs).with(project.full_name, sha: sha, branch: "main", event: "push")
      .and_return([ run.merge(conclusion: "success") ])
    reconcile
    current_head[:sha] = "d" * 40
    allow(client).to receive(:full_verification_runs).with(project.full_name, sha: "d" * 40, branch: "main", event: "push").and_return([])
    comparison = Struct.new(:status).new("behind")
    allow(client).to receive(:compare).with(project.full_name, sha, "b" * 40).and_return(comparison)
    reconcile
    expect(state.reload.episode_key).to be_nil
    expect(state.verified_sha).to eq(sha)
  end

  # @spec MAIN-CI-002
  it "retains a verified workflow failure when job logs are unavailable" do
    allow(client).to receive(:check_runs_for_ref).and_raise(GithubClient::Error, "Checks permission unavailable")
    state = reconcile
    expect(state).to be_blocked
    expect(state.evidence["failed_runs"].first["id"]).to eq(101)
    expect(state.evidence["failure_context_available"]).to be(false)
  end
end
