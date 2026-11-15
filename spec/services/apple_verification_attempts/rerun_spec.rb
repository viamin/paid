# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Rerun do
  # @spec APPLE-VERIFY-006 AGENT-RETRY-016
  it "preserves a capture selection on the retry" do
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure", requested_capture: "ios-app.initial-screen")

    rerun_attempt = described_class.call(attempt:)

    expect(rerun_attempt).to have_attributes(
      requested_capture: "ios-app.initial-screen",
      retry_of_attempt: attempt
    )
  end

  it "returns the existing successor when a terminal source is rerun again" do
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure")

    first = described_class.call(attempt:)
    second = described_class.call(attempt:)

    expect(second.id).to eq(first.id)
    expect(AppleVerificationAttempt.where(retry_of_attempt: attempt)).to have_attributes(count: 1)
  end

  it "leaves no queued rerun behind when the fair queue refuses it" do
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure")

    with_env("APPLE_VERIFICATION_MAXIMUM_QUEUE_DEPTH" => "0") do
      expect { described_class.call(attempt:) }
        .to raise_error(ArgumentError, "Apple verification queue is full")
    end
    expect(AppleVerificationAttempt.where(retry_of_attempt: attempt)).to be_empty
  end

  it "leaves no queued rerun behind when the attempts-per-run limit refuses it" do
    project = create(:project)
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure",
      project:, account: project.account, agent_run: create(:agent_run, project:))

    with_env("APPLE_VERIFICATION_MAXIMUM_ATTEMPTS_PER_RUN" => "0") do
      expect { described_class.call(attempt:) }
        .to raise_error(ArgumentError, "Apple verification attempt limit reached for agent run")
    end
    expect(AppleVerificationAttempt.where(retry_of_attempt: attempt)).to be_empty
  end

  it "refuses an exhausted source with the policy refusal message and a durable reason" do
    attempt = create(:apple_verification_attempt, status: "failed",
      failure_classification: "worker_infrastructure",
      retry_number: AppleVerificationAttempts::Config.max_retries)

    expect { described_class.call(attempt:) }
      .to raise_error(ArgumentError, "attempt failure is not retryable")
    expect(AppleVerificationAttempt.where(retry_of_attempt: attempt)).to be_empty
    expect(OrchestrationDecision.last.outputs["reason"]).to eq("retry_limit_reached")
  end

  it "refuses a deterministic project failure and records its durable reason" do
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "test_assertion")

    expect { described_class.call(attempt:) }
      .to raise_error(ArgumentError, "attempt failure is not retryable")
    expect(OrchestrationDecision.last.outputs["reason"]).to eq("deterministic_project_failure")
  end

  it "refuses an attempt that is still active" do
    attempt = create(:apple_verification_attempt, status: "running")

    expect { described_class.call(attempt:) }
      .to raise_error(ArgumentError, "only a completed attempt can be rerun")
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
