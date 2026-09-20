# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::AppleVerifications" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, apple_verification_mode: "off") }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
    sign_in user
  end

  describe "GET /projects/:project_id/apple_verification" do
    it "presents workflows, attempts, and protected artifacts" do # @spec APPLE-VERIFY-001 # @spec APPLE-VERIFY-004
      attempt = create(:apple_verification_attempt, project:)
      artifact = create_artifact(attempt)

      get project_apple_verification_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        attempt.apple_verification_workflow_revision.content_digest,
        artifact_project_apple_verification_path(project, artifact_id: artifact.id),
        "Protected artifact"
      )
    end
  end

  describe "GET /projects/:project_id/apple_verification/compare" do
    it "presents every workflow field that differs" do # @spec APPLE-VERIFY-005
      revision = create(:apple_verification_workflow_revision, project:, content_digest: digest("b"), required_checks: [ "build" ])
      comparison = create(
        :apple_verification_workflow_revision,
        project:,
        apple_worker_profile: create(:apple_worker_profile, account:),
        content_digest: digest("c"),
        required_checks: [ "test" ]
      )

      get compare_project_apple_verification_path(project), params: { revision_id: revision.id, compare_to_id: comparison.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Content digest", digest("b"), digest("c"), "Required checks", "Worker profile")
    end

    it "does not compare a revision from another project" do # @spec APPLE-VERIFY-005
      revision = create(:apple_verification_workflow_revision, project:)
      other_revision = create(:apple_verification_workflow_revision)

      get compare_project_apple_verification_path(project), params: { revision_id: revision.id, compare_to_id: other_revision.id }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /projects/:project_id/apple_verification/artifact" do
    it "issues a storage URL only after project authorization" do # @spec APPLE-VERIFY-004
      artifact = create_artifact(create(:apple_verification_attempt, project:))
      storage = instance_double(ArtifactStorage, signed_url: "https://artifacts.example.test/capture")
      allow(ArtifactStorage).to receive(:new).and_return(storage)

      get artifact_project_apple_verification_path(project), params: { artifact_id: artifact.id }

      expect(response).to redirect_to("https://artifacts.example.test/capture")
      expect(storage).to have_received(:signed_url).with(artifact.storage_key)
    end

    it "does not issue a storage URL outside the project account" do # @spec APPLE-VERIFY-004 # @spec TENANT-ACCESS-001
      artifact = create_artifact(create(:apple_verification_attempt, project:))
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
    it "updates the project verification mode" do # @spec APPLE-VERIFY-001
      patch project_apple_verification_path(project), params: { project: { mode: "on_demand" } }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(project.reload.apple_verification_mode).to eq("on_demand")
    end
  end

  describe "POST /projects/:project_id/apple_verification/approve" do
    it "approves a draft revision for a project administrator" do # @spec APPLE-VERIFY-002
      project_admin = create(:user, :viewer, account:)
      project_admin.add_role(:project_admin, project)
      revision = create(:apple_verification_workflow_revision, project:)
      sign_out user
      sign_in project_admin

      post approve_project_apple_verification_path(project), params: { revision_id: revision.id }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(revision.reload).to be_approved
    end
  end

  def create_artifact(attempt)
    AppleVerificationArtifact.create!(
      apple_verification_attempt: attempt,
      kind: "screenshot",
      storage_key: "apple-verification/#{attempt.id}/screenshot.png"
    )
  end

  def digest(character)
    "sha256:#{character * 64}"
  end
end
