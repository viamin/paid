# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempt do
  it "requires a reason for a one-attempt waiver" do # @spec APPLE-VERIFY-003
    attempt = build(:apple_verification_attempt, state: "waived")

    expect(attempt).to be_invalid
    expect(attempt.errors[:waiver_reason]).to be_present
  end

  it "keeps infrastructure and project failures distinct" do # @spec APPLE-VERIFY-003
    expect(build(:apple_verification_attempt, failure_class: "infrastructure")).to be_valid
    expect(build(:apple_verification_attempt, failure_class: "compile")).to be_valid
  end

  it "exposes a predicate for passed attempts" do # @spec APPLE-VERIFY-003
    expect(build(:apple_verification_attempt, state: "passed")).to be_passed
  end

  describe "lifecycle transitions" do
    it "cancels active attempts with a cancellation classification" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, state: "running")

      attempt.cancel!

      expect(attempt.reload).to have_attributes(state: "cancelled", failure_class: "cancellation", cancelled_at: be_present)
    end

    it "only cancels queued or running attempts" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, state: "passed")

      expect { attempt.cancel! }
        .to raise_error(described_class::InvalidTransitionError, "only queued or running attempts can be cancelled")

      expect(attempt.reload).to be_passed
    end

    it "only waives failed attempts for required approved workflows" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, state: "passed")

      expect { attempt.waive!(attempt.project.created_by, "Not needed") }
        .to raise_error(described_class::InvalidTransitionError, "only failed required attempts can be waived")

      expect(attempt.reload).to be_passed
    end

    it "waives a failed attempt for a required approved workflow" do # @spec APPLE-VERIFY-003
      revision = create(:apple_verification_workflow_revision, :approved)
      attempt = create(:apple_verification_attempt, project: revision.project, workflow_revision: revision, state: "failed")

      attempt.waive!(attempt.project.created_by, "Not needed")

      expect(attempt.reload).to have_attributes(state: "waived", waived_by: attempt.project.created_by, waiver_reason: "Not needed")
    end


    it "only records retained VM destruction for failed attempts" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, state: "running")

      expect { attempt.record_retained_vm_destruction! }
        .to raise_error(described_class::InvalidTransitionError, "only failed attempts can have retained VMs destroyed")

      expect(attempt.reload.retained_vm_destroyed_at).to be_nil
    end

    it "records retained VM destruction for failed attempts" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, state: "failed")

      attempt.record_retained_vm_destruction!

      expect(attempt.reload.retained_vm_destroyed_at).to be_present
    end

    it "queues a retry attempt for the same workflow revision" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, state: "failed")

      retry_attempt = attempt.retry!

      expect(retry_attempt).to have_attributes(project: attempt.project, workflow_revision: attempt.workflow_revision, retry_of: attempt)
    end

    it "refuses to retry a disabled workflow revision" do # @spec APPLE-VERIFY-003
      revision = create(:apple_verification_workflow_revision, state: "disabled")
      attempt = create(:apple_verification_attempt, project: revision.project, workflow_revision: revision, state: "failed")

      expect { attempt.retry! }
        .to raise_error(described_class::InvalidTransitionError, "cannot rerun a disabled workflow revision")

      expect(described_class.count).to eq(1)
    end
  end
end
