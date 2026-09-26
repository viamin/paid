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

      it "drives the destroy before revocation and before recording the terminal state" do
        order = []
        allow(lifecycle).to receive(:destroy) { order << :destroy; :destroyed }
        allow(revocation).to receive(:call) { order << :revoke; revocation_result }

        described_class.call(attempt: attempt, outcome: "succeeded", lifecycle: lifecycle, revocation: revocation)

        expect(order).to eq([ :destroy, :revoke ])
      end

      it "records the destroyed audit event only when the lifecycle destroy really happened" do
        described_class.call(attempt: attempt, outcome: "succeeded", lifecycle: lifecycle)

        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed", apple_verification_attempt_id: attempt.id).count).to eq(1)
        expect(attempt.reload.container_retained_until).to be_nil
      end

      it "retains the VM behind the failure window when the immediate destroy raises" do
        failing_lifecycle = instance_double(AppleVerification::Lifecycle)
        allow(failing_lifecycle).to receive(:destroy).and_raise(StandardError, "host unreachable")

        result = described_class.call(attempt: attempt, outcome: "succeeded", lifecycle: failing_lifecycle)

        expect(result.outcome).to eq("succeeded")
        expect(result.retained_until).to be_within(2.seconds).of(1.hour.from_now)
        expect(attempt.reload.status).to eq("succeeded")
        expect(attempt.container_retained_until).to be_within(2.seconds).of(1.hour.from_now)
        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed", apple_verification_attempt_id: attempt.id).count).to eq(0)
        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.retained", apple_verification_attempt_id: attempt.id).count).to eq(1)
      end

      it "retains the VM when the lifecycle destroy is a no-op" do
        noop_lifecycle = instance_double(AppleVerification::Lifecycle, destroy: :noop)

        described_class.call(attempt: attempt, outcome: "succeeded", lifecycle: noop_lifecycle)

        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed", apple_verification_attempt_id: attempt.id).count).to eq(0)
        expect(attempt.reload.container_retained_until).to be_within(2.seconds).of(1.hour.from_now)
      end

      it "retains the VM when no lifecycle is configured instead of recording a destroy it cannot back up" do
        result = described_class.call(attempt: attempt, outcome: "succeeded")

        expect(result.retained_until).to be_within(2.seconds).of(1.hour.from_now)
        expect(attempt.reload.status).to eq("succeeded")
        expect(attempt.container_retained_until).to be_within(2.seconds).of(1.hour.from_now)
        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed", apple_verification_attempt_id: attempt.id).count).to eq(0)
        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.retained", apple_verification_attempt_id: attempt.id).count).to eq(1)
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

    context "with a host-safety termination (terminate_vm)" do
      it "drives the destroy for a non-success outcome and records a real destroy" do
        lifecycle = instance_double(AppleVerification::Lifecycle, destroy: :destroyed)

        result = described_class.call(
          attempt: attempt,
          outcome: "unavailable",
          failure_classification: "worker_infrastructure",
          lifecycle: lifecycle,
          terminate_vm: true
        )

        expect(result.outcome).to eq("unavailable")
        expect(result.retained_until).to be_nil
        expect(lifecycle).to have_received(:destroy).with(attempt: attempt, request_id: "complete:#{attempt.id}")
        expect(attempt.reload.status).to eq("unavailable")
        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed", apple_verification_attempt_id: attempt.id).count).to eq(1)
        expect(attempt.container_retained_until).to be_nil
      end

      it "retains the VM when the host-safety destroy fails" do
        failing_lifecycle = instance_double(AppleVerification::Lifecycle)
        allow(failing_lifecycle).to receive(:destroy).and_raise(StandardError, "host unreachable")

        result = described_class.call(
          attempt: attempt,
          outcome: "unavailable",
          failure_classification: "worker_infrastructure",
          lifecycle: failing_lifecycle,
          terminate_vm: true
        )

        expect(result.retained_until).to be_within(2.seconds).of(1.hour.from_now)
        expect(attempt.reload.container_retained_until).to be_within(2.seconds).of(1.hour.from_now)
        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed", apple_verification_attempt_id: attempt.id).count).to eq(0)
        expect(ExecutionAuditEvent.where(event_name: "apple_verification_vm.retained", apple_verification_attempt_id: attempt.id).count).to eq(1)
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
