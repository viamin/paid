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
  end
end
