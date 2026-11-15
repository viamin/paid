# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::RetryMonitor do
  # @spec APPLE-ATTEMPT-010 AGENT-RETRY-006 AGENT-RETRY-016

  it "re-enqueues an unavailable worker-infrastructure attempt with an immutable successor" do
    original = create(:apple_verification_attempt, :committed, status: "unavailable",
      failure_classification: "worker_infrastructure", requested_capture: "ios-app.launch")

    result = described_class.call

    expect(result.retried).to eq(1)
    expect(result.scanned).to eq(1)

    retry_attempt = AppleVerificationAttempt.find_by(retry_of_attempt: original)
    expect(retry_attempt).to be_present
    expect(retry_attempt).to have_attributes(
      status: "queued",
      retry_number: 1,
      account: original.account,
      agent_run: original.agent_run,
      apple_verification_workflow_revision: original.apple_verification_workflow_revision,
      apple_worker_profile: original.apple_worker_profile,
      source_digest: original.source_digest,
      commit_sha: original.commit_sha,
      requested_capture: original.requested_capture,
      lifecycle_gate: original.lifecycle_gate
    )
  end

  it "does not re-enqueue a deterministic project failure" do
    create(:apple_verification_attempt, status: "failed", failure_classification: "test_assertion")

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty
  end

  it "stops at the retry limit without scanning the exhausted source" do
    create(
      :apple_verification_attempt,
      status: "unavailable",
      failure_classification: "worker_infrastructure",
      retry_number: AppleVerificationAttempts::Config.max_retries
    )

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty
  end

  it "does not re-enqueue when the queue is already full" do
    create(:apple_verification_attempt, status: "unavailable", failure_classification: "worker_infrastructure")
    allow(AppleVerificationAttempts::Queue).to receive(:full?).and_return(true)

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty
  end

  it "does not scan an attempt that already has a retry on a duplicate pass" do
    original = create(:apple_verification_attempt, status: "unavailable", failure_classification: "worker_infrastructure")
    create(:apple_verification_attempt, retry_of_attempt: original)

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(AppleVerificationAttempt.where(status: "queued").count).to eq(1)
  end

  it "tallies refused claims by inspectable reason and records the durable noop" do
    project = create(:project)
    create(:apple_verification_attempt, status: "unavailable", failure_classification: "worker_infrastructure",
      project:, account: project.account, agent_run: create(:agent_run, project:))

    result = with_env("APPLE_VERIFICATION_MAXIMUM_ATTEMPTS_PER_RUN" => "0") { described_class.call }

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(1)
    expect(result.skipped).to include(run_attempt_limit_reached: 1)
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty

    decision = OrchestrationDecision.last
    expect(decision.context["apple_verification_attempt_id"]).to be_present
    expect(decision.outputs["reason"]).to eq("run_attempt_limit_reached")
  end

  private

  def with_env(overrides)
    previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
