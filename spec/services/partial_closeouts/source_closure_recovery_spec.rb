# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SourceClosureRecovery do # @spec PARTIAL-CLOSEOUT-043 @spec PARTIAL-CLOSEOUT-045
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project, github_state: "open") }
  let(:commit_sha) { "abc123def456789012345678901234567890abcd" }
  let(:agent_run) do
    create(:agent_run, project: project, issue: issue, status: "paused", paused_at: Time.current,
      branch_name: "agent/issue-42", result_commit_sha: commit_sha)
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:assessment) { { "gaps" => [], "criteria" => [ { "criterion" => "dispatch", "state" => "satisfied" } ] } }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:ref).and_return(double(object: double(sha: commit_sha)))
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)
    allow(Activities::CreatePullRequestActivity).to receive(:new).and_return(
      instance_double(Activities::CreatePullRequestActivity,
        execute: { agent_run_id: agent_run.id, pull_request_url: "https://github.com/example/repo/pull/9",
                   pull_request_number: 9 })
    )
    allow(Activities::ReconcilePartialCloseoutActivity).to receive(:new).and_return(
      instance_double(Activities::ReconcilePartialCloseoutActivity, execute: { agent_run_id: agent_run.id, gaps_remain: false })
    )
    allow(Activities::AdvancePartialCloseoutActivity).to receive(:new).and_return(
      instance_double(Activities::AdvancePartialCloseoutActivity, execute: { agent_run_id: agent_run.id })
    )
    allow(Activities::UpdateIssueWithPrActivity).to receive(:new).and_return(
      instance_double(Activities::UpdateIssueWithPrActivity, execute: { agent_run_id: agent_run.id })
    )
  end

  # Parks the run the way the workflow does when the assessment exhausts its
  # immediate retry budget.
  def park_for_recovery(category: "timeout", attempts: 5)
    error = Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
      category: category)
    PartialCloseouts::SourceClosureRecoveryState.record_attempt(agent_run, error: error,
      branch: agent_run.branch_name, commit_sha: agent_run.result_commit_sha)
    agent_run.update!(reconciliation: agent_run.reconciliation.merge(
      "source_closure_recovery" => PartialCloseouts::SourceClosureRecoveryState.state(agent_run).merge(
        "status" => "waiting", "attempts" => attempts, "next_retry_at" => 1.minute.ago.iso8601
      )
    ))
    agent_run.reload
  end

  describe "#call" do
    it "recovers the assessment and publishes the pull request once" do
      park_for_recovery

      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("recovered")
      expect(PartialCloseouts::SourceClosureRecoveryState.state(agent_run.reload)["status"]).to eq("recovered")
      expect(Activities::CreatePullRequestActivity).to have_received(:new).once
    end

    it "keeps the pushed revision and never re-runs coding" do
      park_for_recovery
      run_count = AgentRun.count

      described_class.call(agent_run: agent_run)

      expect(AgentRun.count).to eq(run_count)
      expect(agent_run.reload.result_commit_sha).to eq(commit_sha)
    end

    it "does not publish a pull request while the assessment is unavailable" do
      park_for_recovery
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(
        Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
          category: "timeout")
      )

      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("waiting")
      expect(Activities::CreatePullRequestActivity).not_to have_received(:new)
      expect(PartialCloseouts::SourceClosureRecoveryState.state(agent_run.reload)["status"]).to eq("waiting")
    end

    it "records the pushed branch, commit, and attempts while waiting" do
      park_for_recovery
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(
        Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
          category: "timeout")
      )

      described_class.call(agent_run: agent_run)

      state = PartialCloseouts::SourceClosureRecoveryState.state(agent_run.reload)
      expect(state).to include("branch" => "agent/issue-42", "commit_sha" => commit_sha)
      expect(state["attempts"].to_i).to be >= 5
      expect(state["failure_category"]).to eq("timeout")
    end

    it "refuses to recover a run whose pushed branch moved" do
      park_for_recovery
      allow(github_client).to receive(:ref).and_return(double(object: double(sha: "9999999999999999999999999999999999999999")))

      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("abandoned")
      expect(Activities::CreatePullRequestActivity).not_to have_received(:new)
      expect(PartialCloseouts::SourceClosureRecoveryState.state(agent_run.reload)["failure_category"]).to eq("branch_moved")
    end

    it "refuses to recover a run whose pushed branch was deleted" do
      park_for_recovery
      allow(github_client).to receive(:ref).and_raise(GithubClient::NotFoundError.new("missing"))

      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("abandoned")
      expect(Activities::CreatePullRequestActivity).not_to have_received(:new)
    end

    it "does not recover a cancelled run" do
      park_for_recovery
      agent_run.update!(status: "cancelled", completed_at: Time.current)

      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("skipped")
      expect(Activities::CreatePullRequestActivity).not_to have_received(:new)
    end

    it "refuses a concurrent recovery so the pull request is published once" do
      park_for_recovery

      first = described_class.call(agent_run: agent_run)
      second = described_class.call(agent_run: agent_run)

      expect(first.status).to eq("recovered")
      expect(second.status).to eq("skipped")
      expect(Activities::CreatePullRequestActivity).to have_received(:new).once
    end

    it "recovers from durable state after a worker restart" do
      park_for_recovery
      reloaded = AgentRun.find(agent_run.id)

      result = described_class.call(agent_run: reloaded)

      expect(result.status).to eq("recovered")
      expect(Activities::CreatePullRequestActivity).to have_received(:new).once
    end

    it "skips a run that is not waiting for recovery" do
      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("skipped")
      expect(Activities::CreatePullRequestActivity).not_to have_received(:new)
    end

    it "holds the recovery while an explicit operator pause is active" do
      park_for_recovery
      project.update!(paused: true)

      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("waiting")
      expect(Activities::CreatePullRequestActivity).not_to have_received(:new)
      expect(PartialCloseouts::SourceClosureRecoveryState.state(agent_run.reload)["failure_category"])
        .to eq("execution_paused")
    end

    it "holds the recovery when the execution budget is exhausted" do
      park_for_recovery
      agent_run.update!(token_limit_status: "exceeded")

      result = described_class.call(agent_run: agent_run)

      expect(result.status).to eq("waiting")
      expect(Activities::CreatePullRequestActivity).not_to have_received(:new)
    end

    it "restores and releases the isolated assessment environment when the runner needs isolation" do
      park_for_recovery
      agent_run.update!(runner: create(:runner, user: project.effective_owner, runner_key: "codex",
        auth_type: "subscription"))
      allow(agent_run).to receive(:provision_execution_environment)
      allow(agent_run).to receive(:cleanup_execution_environment)

      described_class.call(agent_run: agent_run)

      expect(agent_run).to have_received(:provision_execution_environment)
      expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    end
  end
end
