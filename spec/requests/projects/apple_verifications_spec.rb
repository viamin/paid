# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::AppleVerifications" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, apple_verification_settings: { "mode" => "off", "profiles" => [ "ios" ] }) }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
    sign_in user
  end

  describe "PATCH /projects/:project_id/apple_verification" do
    # @spec APPLE-VERIFY-001
    it "preserves inferred profiles when updating the verification mode" do
      patch project_apple_verification_path(project), params: { project: { mode: "on_demand" } }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(project.reload.apple_verification_settings).to eq({ "mode" => "on_demand", "profiles" => [ "ios" ] })
    end

    it "ignores submitted profiles" do # @spec APPLE-VERIFY-001
      patch project_apple_verification_path(project), params: { project: { mode: "on_demand", profiles: { name: "untrusted" } } }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(project.reload.apple_verification_settings).to eq({ "mode" => "on_demand", "profiles" => [ "ios" ] })
    end
  end

  describe "project administrator lifecycle controls" do
    let(:project_admin) { create(:user, :viewer, account:) }
    let(:draft_revision) { create(:apple_verification_workflow_revision, project:) }
    let(:approved_revision) { create(:apple_verification_workflow_revision, :approved, project:) }

    before do
      project_admin.add_role(:project_admin, project)
      sign_out user
      sign_in project_admin
    end

    it "approves draft revisions" do # @spec APPLE-VERIFY-002
      post approve_project_apple_verification_path(project), params: { revision_id: draft_revision.id }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(draft_revision.reload).to be_approved
    end

    it "waives failed required attempts" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, project:, workflow_revision: approved_revision, state: "failed")

      post waive_project_apple_verification_path(project), params: { attempt_id: attempt.id, reason: "Not needed" }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(attempt.reload).to be_waived
    end

    it "records retained VM destruction for failed attempts" do # @spec APPLE-VERIFY-003
      attempt = create(:apple_verification_attempt, project:, workflow_revision: approved_revision, state: "failed")

      post destroy_retained_vm_project_apple_verification_path(project), params: { attempt_id: attempt.id }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(attempt.reload.retained_vm_destroyed_at).to be_present
    end
  end

  describe "POST /projects/:project_id/apple_verification/rerun" do
    # @spec APPLE-VERIFY-003
    it "does not queue a rerun while the project mode is off" do
      attempt = create(:apple_verification_attempt, project:)

      expect {
        post rerun_project_apple_verification_path(project), params: { attempt_id: attempt.id }
      }.not_to change(AppleVerificationAttempt, :count)

      expect(response).to redirect_to(root_path)
    end
  end
end
