# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationWorkflowRevision do
  describe "#approve!" do
    it "supersedes the project approval and records the approving user" do # @spec APPLE-VERIFY-002
      project = create(:project)
      prior = create(:apple_verification_workflow_revision, :approved, project:)
      revision = create(:apple_verification_workflow_revision, project:)

      revision.approve!(project.created_by)

      expect(revision.reload).to have_attributes(state: "approved", approved_by: project.created_by, approved_at: be_present)
      expect(prior.reload.state).to eq("superseded")
    end

    it "only approves draft revisions" do # @spec APPLE-VERIFY-002
      project = create(:project)
      current_approval = create(:apple_verification_workflow_revision, :approved, project:)
      revision = create(:apple_verification_workflow_revision, project:, state: "disabled")

      expect { revision.approve!(revision.project.created_by) }
        .to raise_error(AppleVerificationWorkflowRevision::InvalidTransitionError, "only draft revisions can be approved")

      expect(current_approval.reload).to be_approved
    end

    it "serializes concurrent approvals of different draft revisions so only one wins" do # @spec APPLE-VERIFY-002
      project = create(:project)
      prior = create(:apple_verification_workflow_revision, :approved, project:)
      revision_a = create(:apple_verification_workflow_revision, project:)
      revision_b = create(:apple_verification_workflow_revision, project:)

      approve_concurrently([ revision_a, revision_b ], project.created_by)

      expect(project.apple_verification_workflow_revisions.approved.count).to eq(1)
      expect([ revision_a.reload, revision_b.reload ].count(&:approved?)).to eq(1)
      expect(prior.reload.state).to eq("superseded")
    end
  end

  # Approves each revision from its own thread, released simultaneously via a
  # barrier, so a lock that only serializes on the receiver (not the shared
  # project) would let both approvals see no approved revision and both win.
  def approve_concurrently(revisions, user)
    mutex = Mutex.new
    cv = ConditionVariable.new
    ready = 0

    threads = revisions.map do |revision|
      Thread.new do
        mutex.synchronize do
          ready += 1
          cv.broadcast if ready == revisions.size
          cv.wait(mutex) until ready == revisions.size
        end
        revision.approve!(user)
      end
    end
    threads.each(&:join)
  end
end
