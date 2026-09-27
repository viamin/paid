# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Rerun do
  # @spec APPLE-VERIFY-006
  it "preserves a capture selection on the retry" do
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure", requested_capture: "ios-app.initial-screen")

    rerun_attempt = described_class.call(attempt:)

    expect(rerun_attempt).to have_attributes(
      requested_capture: "ios-app.initial-screen",
      retry_of_attempt: attempt
    )
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

  private

  def with_env(overrides)
    previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
