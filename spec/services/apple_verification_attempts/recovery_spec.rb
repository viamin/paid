# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Recovery do
  # @spec APPLE-ATTEMPT-014

  let(:project) { create(:project) }

  def attempt_with(status:)
    create(:apple_verification_attempt, project:, status:)
  end

  def vm_entry(attempt, status:)
    create(
      :execution_resource_ledger_entry,
      apple_verification_attempt: attempt,
      account: attempt.account,
      project: attempt.project,
      resource_kind: "verification_vm",
      tags: {},
      status:
    )
  end

  it "reconciles a provisioning attempt whose VM is already deleted" do
    attempt = attempt_with(status: "provisioning")
    vm_entry(attempt, status: "deleted")
    complete = spy

    result = described_class.call(complete: complete)

    expect(result.scanned).to eq(1)
    expect(result.reconciled).to eq(1)
    expect(complete).to have_received(:call).with(
      attempt: attempt,
      outcome: "unavailable",
      failure_classification: "worker_infrastructure"
    )
  end

  it "reconciles an in-flight attempt that never linked a VM" do
    attempt = attempt_with(status: "provisioning")
    complete = spy

    result = described_class.call(complete: complete)

    expect(result.scanned).to eq(1)
    expect(result.reconciled).to eq(1)
    expect(complete).to have_received(:call).with(
      attempt: attempt,
      outcome: "unavailable",
      failure_classification: "worker_infrastructure"
    )
  end

  it "does not reconcile a running attempt with a live active VM" do
    attempt = attempt_with(status: "running")
    vm_entry(attempt, status: "active")
    complete = spy

    result = described_class.call(complete: complete)

    expect(result.scanned).to eq(1)
    expect(result.reconciled).to eq(0)
    expect(complete).not_to have_received(:call)
  end

  it "reconciles a running attempt with an orphaned VM" do
    attempt = attempt_with(status: "running")
    vm_entry(attempt, status: "orphaned")
    complete = spy

    result = described_class.call(complete: complete)

    expect(result.scanned).to eq(1)
    expect(result.reconciled).to eq(1)
    expect(complete).to have_received(:call).with(
      attempt: attempt,
      outcome: "unavailable",
      failure_classification: "worker_infrastructure"
    )
  end

  it "does not scan queued attempts" do
    attempt_with(status: "queued")
    complete = spy

    result = described_class.call(complete: complete)

    expect(result.scanned).to eq(0)
    expect(result.reconciled).to eq(0)
    expect(complete).not_to have_received(:call)
  end

  it "converges idempotently: re-running after a reconcile finds none" do
    attempt = attempt_with(status: "provisioning")
    complete = lambda do |attempt:, outcome:, failure_classification:|
      attempt.update!(status: outcome, finished_at: Time.current, failure_classification:)
    end

    first = described_class.call(complete: complete)
    second = described_class.call(complete: complete)

    expect(first.scanned).to eq(1)
    expect(first.reconciled).to eq(1)
    expect(second.scanned).to eq(0)
    expect(second.reconciled).to eq(0)
  end
end
