# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Complete do
  # @spec APPLE-ATTEMPT-006
  describe ".call" do
    let(:attempt) { create(:apple_verification_attempt, :committed) }

    context "with a succeeded outcome" do
      let(:lifecycle) { instance_double(AppleVerification::Lifecycle, destroy: :destroyed) }
      let(:revocation_result) { AppleVerification::Revocation::Enforce::Result.new(outcome: "verification_vm_destroyed", retained_until: nil, audit_event: nil) }
      let(:revocation) { instance_double(AppleVerification::Revocation::Enforce, call: revocation_result) }

      it "marks the attempt succeeded, destroys the VM, and revokes credentials" do
        result = described_class.call(
          attempt: attempt,
          outcome: "succeeded",
          lifecycle: lifecycle,
          revocation: revocation
        )

        expect(result.outcome).to eq("succeeded")
        expect(result.retained_until).to be_nil
        expect(attempt.reload.status).to eq("succeeded")
        expect(attempt.finished_at).to be_present
        expect(lifecycle).to have_received(:destroy).with(attempt: attempt, request_id: "complete:#{attempt.id}")
        expect(revocation).to have_received(:call)
      end
    end

    context "with a failed outcome" do
      let(:retained_until) { 1.hour.from_now }
      let(:revocation_result) { AppleVerification::Revocation::Enforce::Result.new(outcome: "verification_vm_retained", retained_until: retained_until, audit_event: nil) }
      let(:revocation) { instance_double(AppleVerification::Revocation::Enforce, call: revocation_result) }
      let(:lifecycle) { instance_double(AppleVerification::Lifecycle, destroy: :destroyed) }

      it "marks the attempt failed and propagates the retention window without destroying the VM" do
        result = described_class.call(
          attempt: attempt,
          outcome: "failed",
          failure_classification: "capacity_or_quota",
          lifecycle: lifecycle,
          revocation: revocation
        )

        expect(result.outcome).to eq("failed")
        expect(result.retained_until).to eq(retained_until)
        expect(result.failure_classification).to eq("capacity_or_quota")
        expect(attempt.reload.status).to eq("failed")
        expect(attempt.finished_at).to be_present
        expect(lifecycle).not_to have_received(:destroy)
        expect(revocation).to have_received(:call)
      end

      it "revokes credentials before recording the terminal state" do
        allow(revocation).to receive(:call) do
          expect(attempt.status).not_to eq("failed")
          revocation_result
        end

        described_class.call(
          attempt: attempt,
          outcome: "failed",
          failure_classification: "capacity_or_quota",
          revocation: revocation
        )
      end
    end

    context "with the configured failed-VM retention window" do
      around do |example|
        original = ENV.fetch("APPLE_VERIFICATION_FAILED_VM_RETENTION_HOURS", nil)
        ENV["APPLE_VERIFICATION_FAILED_VM_RETENTION_HOURS"] = "2"
        example.run
      ensure
        ENV["APPLE_VERIFICATION_FAILED_VM_RETENTION_HOURS"] = original
      end

      it "uses the configured retention window" do
        uncommitted_attempt = create(:apple_verification_attempt)

        described_class.call(
          attempt: uncommitted_attempt,
          outcome: "failed",
          failure_classification: "capacity_or_quota"
        )

        expect(uncommitted_attempt.reload.container_retained_until).to be_within(2.seconds).of(2.hours.from_now)
      end
    end

    context "with a non-terminal outcome" do
      it "raises ArgumentError" do
        expect do
          described_class.call(attempt: attempt, outcome: "queued")
        end.to raise_error(ArgumentError)
      end
    end
  end
end
