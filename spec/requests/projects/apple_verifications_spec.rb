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

  describe "GET /projects/:project_id/apple_verification/compare" do
    it "presents the fields that differ between two project revisions" do # @spec APPLE-VERIFY-005
      revision = create(:apple_verification_workflow_revision, project:, source_digest: "sha256:before", checks: { "build" => "required" })
      comparison_revision = create(:apple_verification_workflow_revision, project:, source_digest: "sha256:after", checks: { "build" => "advisory" })

      get compare_project_apple_verification_path(project), params: { revision_id: revision.id, compare_to_id: comparison_revision.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Source digest", "sha256:before", "sha256:after", "Required checks")
    end

    it "does not compare a revision from another project" do # @spec APPLE-VERIFY-005
      revision = create(:apple_verification_workflow_revision, project:)
      other_revision = create(:apple_verification_workflow_revision)

      get compare_project_apple_verification_path(project), params: { revision_id: revision.id, compare_to_id: other_revision.id }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /projects/:project_id/apple_verification/artifact" do
    it "renders protected artifact links in the verification page" do # @spec APPLE-VERIFY-004
      artifact = AppleVerificationArtifact.create!(
        attempt: create(:apple_verification_attempt, project:),
        kind: "recording",
        storage_key: "apple-verification/capture.webm"
      )

      get project_apple_verification_path(project)

      expect(response.body).to include("Protected artifact", artifact_project_apple_verification_path(project, artifact_id: artifact.id))
    end

    it "authorizes the project before redirecting to a protected artifact URL" do # @spec APPLE-VERIFY-004
      artifact = AppleVerificationArtifact.create!(
        attempt: create(:apple_verification_attempt, project:),
        kind: "screenshot",
        storage_key: "apple-verification/capture.png"
      )
      storage = instance_double(ArtifactStorage, signed_url: "https://artifacts.example.test/capture")
      allow(ArtifactStorage).to receive(:new).and_return(storage)

      get artifact_project_apple_verification_path(project), params: { artifact_id: artifact.id }

      expect(response).to redirect_to("https://artifacts.example.test/capture")
      expect(storage).to have_received(:signed_url).with(artifact.storage_key)
    end

    it "does not issue a protected URL to a user outside the project account" do # @spec APPLE-VERIFY-004 # @spec TENANT-ACCESS-001
      artifact = AppleVerificationArtifact.create!(
        attempt: create(:apple_verification_attempt, project:),
        kind: "screenshot",
        storage_key: "apple-verification/capture.png"
      )
      storage = instance_double(ArtifactStorage)
      allow(ArtifactStorage).to receive(:new).and_return(storage)
      allow(storage).to receive(:signed_url)
      sign_out user
      sign_in create(:user, :owner)

      get artifact_project_apple_verification_path(project), params: { artifact_id: artifact.id }

      expect(response).to have_http_status(:not_found)
      expect(storage).not_to have_received(:signed_url)
    end
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

    it "reports an invalid verification mode" do # @spec APPLE-VERIFY-001
      patch project_apple_verification_path(project), params: { project: { mode: "unsupported" } }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(flash[:alert]).to include("mode must be one of off, on_demand, automatic")
      expect(project.reload.apple_verification_settings).to eq({ "mode" => "off", "profiles" => [ "ios" ] })
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

    context "when the project mode permits on-demand execution" do
      let(:project) { create(:project, account:, apple_verification_settings: { "mode" => "on_demand" }) }

      it "queues a rerun for an approved workflow revision" do
        revision = create(:apple_verification_workflow_revision, :approved, project:)
        attempt = create(:apple_verification_attempt, project:, workflow_revision: revision, state: "failed")

        expect {
          post rerun_project_apple_verification_path(project), params: { attempt_id: attempt.id }
        }.to change(AppleVerificationAttempt, :count).by(1)

        expect(response).to redirect_to(project_apple_verification_path(project))
      end

      it "rejects a rerun for a disabled workflow revision" do
        revision = create(:apple_verification_workflow_revision, project:, state: "disabled")
        attempt = create(:apple_verification_attempt, project:, workflow_revision: revision, state: "failed")

        expect {
          post rerun_project_apple_verification_path(project), params: { attempt_id: attempt.id }
        }.not_to change(AppleVerificationAttempt, :count)

        expect(response).to redirect_to(project_apple_verification_path(project))
        follow_redirect!
        expect(response.body).to include("cannot rerun a disabled workflow revision")
      end
    end
  end
end
