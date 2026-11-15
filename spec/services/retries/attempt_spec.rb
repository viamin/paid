# frozen_string_literal: true

require "rails_helper"

# @spec AGENT-RETRY-004 AGENT-RETRY-005 AGENT-RETRY-007 AGENT-RETRY-015 AGENT-RETRY-016
RSpec.describe Retries::Attempt do
  let(:manual_mechanics) do
    described_class.new(policy: AgentRuns::ManualRunRetryPolicy.new, decision_point: "manual_failed_run_auto_retry")
  end

  let(:apple_mechanics) do
    described_class.new(
      policy: AppleVerificationAttempts::RetryPolicy.new,
      decision_point: AppleVerificationAttempts::RetryPolicy::DECISION_POINT
    )
  end

  describe "#claim with the manual-run policy" do
    it "mints a successor, marks the source retried, and records the applied decision" do
      original = create(:agent_run, :failed, :manual, :with_custom_prompt, goal: "create_pr")

      result = manual_mechanics.claim(source_id: original.id, attempt_number: 1)

      expect(result).to be_claimed
      expect(result.reason).to eq(:retry_claimed)
      expect(original.reload.status).to eq("retried")

      successor = result.successor
      expect(successor.status).to eq("queued")
      expect(successor.external_metadata[AgentRun::MANUAL_RETRY_PARENT_METADATA_KEY]).to eq(original.id)
      expect(successor.external_metadata[AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY]).to eq(1)

      decision = OrchestrationDecision.last
      expect(decision.agent_run).to eq(original)
      expect(decision.outputs["new_agent_run_id"]).to eq(successor.id)
      expect(decision.outputs["reason"]).to eq("retry_claimed")
    end

    it "skips a re-delivered claim after the source was already retried" do
      original = create(:agent_run, :retried, :manual, :with_custom_prompt, goal: "create_pr")

      result = manual_mechanics.claim(source_id: original.id, attempt_number: 1)

      expect(result).to be_skipped
      expect(result.reason).to eq(:not_failed)
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("not_failed")
    end

    it "skips a missing source without recording a decision" do
      expect {
        result = manual_mechanics.claim(source_id: -1, attempt_number: 1)

        expect(result).to be_skipped
        expect(result.reason).to eq(:missing_source)
      }.not_to change(OrchestrationDecision, :count)
    end
  end

  describe "#claim with the Apple verification policy" do
    it "claims an infrastructure failure and links the immutable successor" do
      source = create(:apple_verification_attempt, :failed,
        failure_classification: "worker_infrastructure", retry_number: 0,
        requested_capture: "ios-app.launch")

      result = apple_mechanics.claim(source_id: source.id)

      expect(result).to be_claimed
      successor = result.successor
      expect(successor).to have_attributes(
        status: "queued",
        retry_number: 1,
        retry_of_attempt: source,
        requested_capture: "ios-app.launch",
        source_digest: source.source_digest
      )
      expect(source.reload.status).to eq("failed")
    end

    it "refuses a duplicate claim with an inspectable reason and one successor" do
      source = create(:apple_verification_attempt, :failed, failure_classification: "capacity_or_quota")

      first = apple_mechanics.claim(source_id: source.id)
      second = apple_mechanics.claim(source_id: source.id)

      expect(first).to be_claimed
      expect(second).to be_skipped
      expect(second.reason).to eq(:successor_already_claimed)
      expect(AppleVerificationAttempt.where(retry_of_attempt: source)).to have_attributes(count: 1)

      decisions = OrchestrationDecision.where(decision_type: AppleVerificationAttempts::RetryPolicy::DECISION_POINT)
      expect(decisions.map { |decision| decision.context["decision_status"] }).to contain_exactly("applied", "noop")
      expect(decisions.map { |decision| decision.outputs["reason"] }).to contain_exactly("retry_claimed", "successor_already_claimed")
    end

    it "records a durable noop reason when the queue refuses admission at claim time" do
      source = create(:apple_verification_attempt, :failed, failure_classification: "worker_infrastructure")
      allow(AppleVerificationAttempts::Queue).to receive(:full?).and_return(true)

      result = apple_mechanics.claim(source_id: source.id)

      expect(result).to be_skipped
      expect(result.reason).to eq(:queue_full)
      expect(AppleVerificationAttempt.where(retry_of_attempt: source)).to be_empty
      expect(OrchestrationDecision.last).to have_attributes(
        actor: AppleVerificationAttempts::RetryPolicy::DECISION_POINT,
        agent_run: source.agent_run
      )
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("queue_full")
      expect(OrchestrationDecision.last.context["apple_verification_attempt_id"]).to eq(source.id)
    end
  end

  describe "#schedule with the manual-run policy" do
    it "enqueues the delayed claim job for an eligible source" do
      original = create(:agent_run, :failed, :manual, :with_custom_prompt, goal: "create_pr")

      expect {
        result = manual_mechanics.schedule(
          source: original,
          job_class: RetryFailedManualRunJob,
          delay: RetryFailedManualRunJob.method(:retry_delay)
        )

        expect(result).to be_scheduled
      }.to have_enqueued_job(RetryFailedManualRunJob).with(original.id, 1)
    end

    it "records a durable skip for an ineligible source without enqueueing" do
      original = create(:agent_run, :failed, :manual, :with_custom_prompt, goal: "create_pr")
      original.project.update!(retry_failed_manual_runs: false)

      expect {
        result = manual_mechanics.schedule(
          source: original,
          job_class: RetryFailedManualRunJob,
          delay: RetryFailedManualRunJob.method(:retry_delay)
        )

        expect(result).to be_skipped
        expect(result.reason).to eq(:project_retry_disabled)
      }.not_to have_enqueued_job(RetryFailedManualRunJob)

      expect(OrchestrationDecision.last.outputs["reason"]).to eq("project_retry_disabled")
    end
  end
end
