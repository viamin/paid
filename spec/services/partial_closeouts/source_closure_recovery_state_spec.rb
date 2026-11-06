# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SourceClosureRecoveryState do # @spec PARTIAL-CLOSEOUT-043
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project, github_state: "open") }
  let(:agent_run) do
    create(:agent_run, project: project, issue: issue, status: "paused",
      branch_name: "agent/issue-42", result_commit_sha: "abc123def456")
  end

  def timeout_error
    Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
      category: "timeout", request_id: "req-1", attempt_id: "attempt-1")
  end

  describe ".record_attempt" do
    it "records the failed step, the pushed revision, the attempts, and the category" do
      described_class.record_attempt(agent_run, error: timeout_error,
        branch: agent_run.branch_name, commit_sha: agent_run.result_commit_sha)

      state = described_class.state(agent_run.reload)

      expect(state).to include(
        "status" => "retrying",
        "step" => "assess_source_closure",
        "branch" => "agent/issue-42",
        "commit_sha" => "abc123def456",
        "attempts" => 1,
        "failure_category" => "timeout",
        "retryable" => true,
        "next_action" => "retry_assessment"
      )
    end

    it "counts every attempt" do
      3.times { described_class.record_attempt(agent_run, error: timeout_error) }

      expect(described_class.state(agent_run.reload)["attempts"]).to eq(3)
    end

    it "does not persist provider payloads or credentials" do
      described_class.record_attempt(agent_run, error: timeout_error)

      expect(described_class.state(agent_run.reload).to_json).not_to include("request_id", "attempt_id")
    end
  end

  describe ".park" do
    it "keeps a bounded failure category and schedules the next retry" do
      described_class.record_attempt(agent_run, error: timeout_error)
      described_class.park(agent_run)

      state = described_class.state(agent_run.reload)

      expect(state["status"]).to eq("waiting")
      expect(state["failure_category"]).to eq("timeout")
      expect(state["next_retry_at"]).to be_present
    end

    it "does not schedule automatic retries for operator-action failures" do
      described_class.record_attempt(agent_run, error: timeout_error)
      described_class.park(agent_run, category: "authentication_unavailable", message: "Reconnect the credential.")

      state = described_class.state(agent_run.reload)

      expect(state["status"]).to eq("waiting")
      expect(state["next_retry_at"]).to be_nil
      expect(state["next_action"]).to eq("reconnect_runner_credential_then_retry")
    end
  end

  describe ".claim" do
    before do
      described_class.record_attempt(agent_run, error: timeout_error)
      described_class.park(agent_run)
    end

    it "claims a pending recovery" do
      expect(described_class.claim(agent_run)).to be true
      expect(described_class.state(agent_run.reload)["status"]).to eq("recovering")
    end

    it "refuses a second claim so a replayed retry cannot publish twice" do
      expect(described_class.claim(agent_run)).to be true

      expect(described_class.claim(agent_run)).to be false
    end
  end

  describe ".recovered" do
    it "records the recovered pull request" do
      described_class.record_attempt(agent_run, error: timeout_error)
      described_class.park(agent_run)

      described_class.recovered(agent_run, pull_request_url: "https://github.com/example/repo/pull/7")

      state = described_class.state(agent_run.reload)

      expect(state["status"]).to eq("recovered")
      expect(state["pull_request_url"]).to eq("https://github.com/example/repo/pull/7")
      expect(state["next_retry_at"]).to be_nil
    end
  end

  describe ".due?" do
    it "is due once the backoff window elapsed" do
      described_class.record_attempt(agent_run, error: timeout_error)
      described_class.park(agent_run)
      agent_run.update!(reconciliation: agent_run.reconciliation.merge(
        "source_closure_recovery" => described_class.state(agent_run).merge("next_retry_at" => 1.minute.ago.iso8601)
      ))

      expect(described_class.due?(agent_run.reload)).to be true
    end

    it "is not due before the backoff window elapsed" do
      described_class.record_attempt(agent_run, error: timeout_error)
      described_class.park(agent_run)

      expect(described_class.due?(agent_run.reload)).to be false
    end
  end
end
