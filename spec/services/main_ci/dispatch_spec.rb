# frozen_string_literal: true

require "rails_helper"

RSpec.describe MainCi::Dispatch do
  let(:revision) { "e" * 40 }
  let(:project) { create(:project, review_settings: { "main_ci_recovery" => {
    "enabled" => true, "required_workflows" => [ ".github/workflows/ci.yml" ], "executor_revision" => revision
  } }) }
  let(:client) { instance_double(GithubClient, check_run_log: "") }
  let(:state) { MainCiState.create!(project: project, account: project.account, status: "failing",
    failed_sha: "a" * 40, verified_sha: "b" * 40, failed_at: Time.current, episode_key: SecureRandom.uuid,
    evidence: { "failed_runs" => [ { "id" => 101, "run_attempt" => 1 } ], "failure_context" => "RSpec test failed" }) }

  before do
    stub_const("ENV", ENV.to_h.merge("PAID_EXECUTOR_REVISION" => revision))
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])
  end

  # @spec MAIN-CI-003 MAIN-CI-004 MAIN-CI-007
  it "queues one isolated repair with baseline and bounded recovery instructions" do
    expect { 2.times { described_class.call(state: state, client: client) } }.to change(AgentRun, :count).by(1)
    run = state.reload.repair_run
    expect(run.goal).to eq("create_pr")
    expect(run.custom_prompt).to include("b" * 40, "Never reset main", "all normal checks", "untrusted diagnostic data")
    expect(run.external_metadata["main_ci_episode"]).to eq(state.episode_key)
    expect(state.dispatched_at).to be_present
  end

  # @spec MAIN-CI-003
  it "keeps the blocker without dispatch on an unverified executor" do
    stub_const("ENV", ENV.to_h.merge("PAID_EXECUTOR_REVISION" => "f" * 40))
    expect { described_class.call(state: state, client: client) }.not_to change(AgentRun, :count)
    expect(state.reload).to be_blocked
  end

  # @spec MAIN-CI-003
  it "commits one infrastructure retry claim before I/O and does not duplicate an ambiguous request" do
    state.update!(evidence: state.evidence.merge("failure_context" => "network error ECONNRESET"))
    allow(client).to receive(:rerun_workflow_run_failed_jobs).and_raise(GithubClient::Error, "ambiguous timeout")
    expect { described_class.call(state: state, client: client) }.to raise_error(GithubClient::Error)
    expect(state.reload.evidence.fetch("retried_run_ids")).to eq([ 101 ])
    expect { described_class.call(state: state, client: client) }.not_to change(AgentRun, :count)
    expect(client).to have_received(:rerun_workflow_run_failed_jobs).once
  end

  # @spec MAIN-CI-003
  it "preserves budget stops and bounds failed repair attempts" do
    allow(CostBudgets::Check).to receive(:call).with(project).and_return({ allowed: false })
    expect { described_class.call(state: state, client: client) }.not_to change(AgentRun, :count)
    allow(CostBudgets::Check).to receive(:call).with(project).and_return({ allowed: true })
    2.times do
      described_class.call(state: state, client: client)
      state.reload.repair_run.update!(status: "failed")
    end
    expect { described_class.call(state: state, client: client) }.not_to change(AgentRun, :count)
    expect(state.reload).to be_blocked
  end
end
