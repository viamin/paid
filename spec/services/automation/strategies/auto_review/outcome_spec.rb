# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoReview::Outcome do
  describe "factories" do
    it "builds a pending outcome with sidecar defaults" do
      outcome = described_class.pending(method: :copilot)

      expect(outcome.state).to eq(:pending)
      expect(outcome).to be_pending
      expect(outcome).not_to be_blocking
      expect(outcome).to be_sidecar
      expect(outcome.method).to eq(:copilot)
      expect(outcome.metadata).to eq({})
    end

    it "builds a blocking pending outcome when requested" do
      outcome = described_class.pending(method: :paid_agent, blocking: true)

      expect(outcome).to be_blocking
      expect(outcome).not_to be_sidecar
    end

    it "builds a satisfied outcome that is never blocking" do
      outcome = described_class.satisfied(method: :copilot)

      expect(outcome).to be_satisfied
      expect(outcome).not_to be_blocking
    end

    it "builds a retryable_failure outcome that blocks by default" do
      outcome = described_class.retryable_failure(method: :paid_agent)

      expect(outcome).to be_retryable_failure
      expect(outcome).to be_blocking
    end

    it "builds an exhausted_retries outcome that blocks by default" do
      outcome = described_class.exhausted_retries(method: :paid_agent)

      expect(outcome).to be_exhausted_retries
      expect(outcome).to be_blocking
    end

    it "builds a not_applicable outcome that is never blocking" do
      outcome = described_class.not_applicable(method: :codex)

      expect(outcome).to be_not_applicable
      expect(outcome).not_to be_blocking
    end
  end

  it "freezes metadata so callers cannot mutate shared state" do
    outcome = described_class.pending(method: :manual, metadata: { reviewer_login: "alice" })

    expect(outcome.metadata).to be_frozen
    expect(outcome.metadata[:reviewer_login]).to eq("alice")
  end

  it "symbolizes method names" do
    outcome = described_class.satisfied(method: "copilot")
    expect(outcome.method).to eq(:copilot)
  end

  it "emits a hash view for logging" do
    outcome = described_class.pending(
      method: :paid_agent,
      blocking: true,
      message: "paid_agent pending",
      metadata: { active_run: true }
    )

    expect(outcome.to_h).to eq(
      method: :paid_agent,
      state: :pending,
      blocking: true,
      message: "paid_agent pending",
      metadata: { active_run: true }
    )
  end

  it "raises on unknown state" do
    expect {
      described_class.send(:build, method: :copilot, state: :weird, blocking: false, message: nil, metadata: {})
    }.to raise_error(ArgumentError, /Unknown outcome state/)
  end
end
